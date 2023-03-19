// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "solmate/tokens/ERC721.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";
import "solmate/utils/SignedWadMath.sol";

import "forge-std/console2.sol";

struct LoanTerms {
    address lender;
    ///////////////////////
    ERC721 nft;
    uint96 maxAmount;
    uint96 minAmount;
    uint96 totalAmount;
    ///////////////////////
    uint16 liquidationDurationBlocks;
    uint32 interestRateBips;
    ///////////////////////
    uint40 deadline;
    uint32 nonce;
}

struct BorrowData {
    bytes32 termsHash;
    address borrower;
    uint256 nftId;
    uint96 lastComputedDebt;
    uint40 lastTouchedTime;
}

contract Puree {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant TERMS_TYPEHASH = keccak256(
        "TermsOffer(address lender,address nft,uint96 maxAmount,uint96 minAmount,uint96 totalAmount,uint16 liquidationDurationBlocks,uint32 interestRateBips,uint40 deadline,uint32 nonce)"
    );

    uint256 internal constant LIQ_THRESHOLD = 100_000; // TODO

    int256 internal constant YEAR_WAD = 365 days * 1e18;

    int256 internal immutable WAD_LOG_LIQ_THRESHOLD = wadLn(int256(LIQ_THRESHOLD * 1e18));

    ERC20 internal immutable weth;

    /*//////////////////////////////////////////////////////////////
                             EIP-712 STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 internal immutable INITIAL_CHAIN_ID;

    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    constructor(ERC20 _weth) {
        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();

        weth = _weth;
    }

    /*//////////////////////////////////////////////////////////////
                                LOAN DATA
    //////////////////////////////////////////////////////////////*/

    mapping(bytes32 => LoanTerms) internal getLoanTerms;

    function getTerms(bytes32 termsHash) external view returns (LoanTerms memory) {
        return getLoanTerms[termsHash];
    }

    mapping(bytes32 => BorrowData) internal getBorrowData;

    function getBorrow(bytes32 termsHash) external view returns (BorrowData memory) {
        return getBorrowData[termsHash];
    }

    // TODO: This could be rolled into terms, but
    // should just be a hash or whatever long term
    mapping(bytes32 => uint256) public getTotalAmountConsumed;

    mapping(bytes32 => uint256) public getAuctionStartBlock;

    /*//////////////////////////////////////////////////////////////
                                USER DATA
    //////////////////////////////////////////////////////////////*/

    mapping(address => uint256) public getNonce;

    function bumpNonce(uint256 n) external {
        getNonce[msg.sender] += n;
    }

    /*//////////////////////////////////////////////////////////////
                               TERMS LOGIC
    //////////////////////////////////////////////////////////////*/

    function submitTerms(LoanTerms calldata terms, uint8 v, bytes32 r, bytes32 s) public returns (bytes32 termsHash) {
        termsHash = hashLoanTerms(terms); // Compute what the terms' hash is going to be.

        // Check the lender listed in the terms has signed the hash.
        require(ecrecover(getTermsDigest(terms), v, r, s) == terms.lender, "INVALID_SIGNATURE");

        // Check the terms are not already submitted.
        require(getLoanTerms[termsHash].deadline == 0, "TERMS_ALREADY_EXISTS");

        // Check the terms are not expired.
        require(checkTermsNotExpired(terms), "TERMS_EXPIRED");

        getLoanTerms[termsHash] = terms; // Store the terms.
    }

    function getTermsDigest(LoanTerms calldata terms) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                getDomainSeparator(),
                keccak256(
                    abi.encode(
                        TERMS_TYPEHASH,
                        terms.lender,
                        terms.nft,
                        terms.maxAmount,
                        terms.minAmount,
                        terms.totalAmount,
                        terms.liquidationDurationBlocks,
                        terms.interestRateBips,
                        terms.deadline,
                        terms.nonce
                    )
                )
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                               LOAN LOGIC
    //////////////////////////////////////////////////////////////*/

    function submitTermsAndBorrow(LoanTerms calldata terms, uint8 v, bytes32 r, bytes32 s, uint256 nftId, uint96 amt)
        external
    {
        bytes32 termsHash = submitTerms(terms, v, r, s); // Submit the terms.
        newBorrow(termsHash, nftId, amt); // Borrow against the terms.
    }

    function newBorrow(bytes32 termsHash, uint256 nftId, uint96 amt) public returns (bytes32 borrowHash) {
        // Get the terms associated with the hash.
        LoanTerms memory termsData = getLoanTerms[termsHash];

        // Check the terms exist and are not expired
        require(checkTermsNotExpired(termsData), "TERMS_EXPIRED_OR_DO_NOT_EXIST");

        // Ensure the amount being borrowed is within the min and max set in the terms.
        require(amt <= termsData.maxAmount && amt >= termsData.minAmount, "INVALID_AMOUNT");

        // Ensure the offer terms still have dry powder associated with them.
        require(termsData.totalAmount >= (getTotalAmountConsumed[termsHash] += amt), "AT_CAPACITY");

        ///////////////////////////////////////////////////////////////////

        // Take the borrower's collateral NFT and keep it in the Puree contract for safe keeping.
        termsData.nft.transferFrom(msg.sender, address(this), nftId);

        // Give the borrower the amount of debt they've requested.
        weth.safeTransferFrom(termsData.lender, msg.sender, amt);

        ///////////////////////////////////////////////////////////////////

        // Create a new borrow data struct with a reference to the terms, the borrower, the nft, the amount, and the time.
        BorrowData memory data = BorrowData(termsHash, msg.sender, nftId, amt, uint40(block.timestamp));

        getBorrowData[borrowHash = hashBorrowData(data)] = data; // Store the borrow data.
    }

    function furtherBorrow(bytes32 borrowHash, uint256 amt) external {
        // Get the borrow data associated with the hash.
        BorrowData storage borrowData = getBorrowData[borrowHash];

        // Ensure the caller is the borrower.
        require(msg.sender == borrowData.borrower, "NOT_BORROWER");

        // Cache the terms hash associated with the borrow data.
        bytes32 termsHash = borrowData.termsHash;

        // Get the terms associated with the borrow.
        LoanTerms memory termsData = getLoanTerms[termsHash];

        // Check the terms exist and are not expired
        require(checkTermsNotExpired(termsData), "TERMS_EXPIRED_OR_DO_NOT_EXIST");

        // Calculate the amount of debt associated with the borrow.
        uint256 debt =
            computeCurrentDebt(borrowData.lastTouchedTime, borrowData.lastComputedDebt, termsData.interestRateBips);

        // Calculate the amount of debt associated with the borrow after furthering.
        uint256 newDebt = debt + amt;

        ///////////////////////////////////////////////////////////////////

        // Ensure the new debt is within the max set in the terms.
        require(newDebt <= termsData.maxAmount, "INVALID_AMOUNT");

        // Ensure the offer terms still have dry powder associated with them.
        require(termsData.totalAmount >= (getTotalAmountConsumed[termsHash] += amt), "AT_CAPACITY");

        // Update the debt calculation variables to account for the furtherance.
        borrowData.lastComputedDebt = uint96(newDebt);
        borrowData.lastTouchedTime = uint40(block.timestamp);

        ///////////////////////////////////////////////////////////////////

        // Give the borrower the amount of collateral they've requested.
        weth.safeTransferFrom(termsData.lender, msg.sender, amt);
    }

    function repay(bytes32 borrowHash, uint96 amt) external {
        // Get the borrow data associated with the hash.
        BorrowData storage borrowData = getBorrowData[borrowHash];

        // Cache the terms hash associated with the borrow data.
        bytes32 termsHash = borrowData.termsHash;

        // Ensure the borrow exists.
        require(termsHash != bytes32(0), "BORROW_DOES_NOT_EXIST");

        // Get the terms associated with the borrow.
        LoanTerms memory termsData = getLoanTerms[termsHash];

        // Get the total amount of the offer terms consumed.
        uint256 consumed = getTotalAmountConsumed[termsHash];

        // Calculate the amount of debt associated with the borrow.
        uint256 debt =
            computeCurrentDebt(borrowData.lastTouchedTime, borrowData.lastComputedDebt, termsData.interestRateBips);

        // If the user has specified a max amount, they want to repay in full.
        if (amt == type(uint96).max) amt = uint96(debt);

        // Calculate the amount of debt associated with the borrow after repayment.
        uint256 newDebt = debt - amt;

        /////////////////////////////////////////////////////////

        // Lower the amount consumed by the amount being repaid,
        // ensuring not to underflow if consumption would be lowered below 0.
        getTotalAmountConsumed[termsHash] = consumed > amt ? consumed - amt : 0;

        // Update the debt calculation variables to account for the repayment.
        borrowData.lastComputedDebt = uint96(newDebt);
        borrowData.lastTouchedTime = uint40(block.timestamp);

        //////////////////////////////////////////////////////

        // Send the lender the repayment.
        weth.safeTransferFrom(msg.sender, termsData.lender, amt);

        // If the user now has no remaining debt:
        if (newDebt == 0) {
            // Give them their NFT back.
            termsData.nft.transferFrom(address(this), borrowData.borrower, borrowData.nftId);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            REFINANCING LOGIC
    //////////////////////////////////////////////////////////////*/

    function instantRefinance(bytes32 borrowHash, bytes32 newTermsHash) external {
        // Get the borrow data associated with the hash.
        BorrowData storage borrowData = getBorrowData[borrowHash];

        // Cache the terms hash associated with the borrow data.
        bytes32 termsHash = borrowData.termsHash;

        // Get the terms associated with the borrow.
        LoanTerms memory termsData = getLoanTerms[termsHash];

        // Ensure the caller is the lender.
        require(msg.sender == termsData.lender, "NOT_LENDER");

        // Get the new terms that will be used for refinancing.
        LoanTerms memory newTermsData = getLoanTerms[newTermsHash];

        // Ensure the new terms exist and are not expired.
        require(checkTermsNotExpired(newTermsData), "TERMS_EXPIRED_OR_DO_NOT_EXIST");

        // Ensure the new terms are favorable to the borrower.
        require(checkTermsFavorable(termsData, newTermsData), "TERMS_NOT_FAVORABLE");

        // Calculate the amount of debt associated with the borrow.
        uint256 debt =
            computeCurrentDebt(borrowData.lastTouchedTime, borrowData.lastComputedDebt, termsData.interestRateBips);

        // Ensure the amount being borrowed is within the min and max set in the terms.
        require(debt >= newTermsData.minAmount && debt <= newTermsData.maxAmount, "INVALID_AMOUNT");

        ///////////////////////////////////////////////////////////////

        // Lower the consumption amount of the original terms by the debt.
        getTotalAmountConsumed[termsHash] -= debt;

        // Increase the consumed amount of the new terms by the debt, or revert if exceeds the capacity.
        require(newTermsData.totalAmount >= (getTotalAmountConsumed[newTermsHash] += debt), "NEW_TERMS_AT_CAPACITY");

        ///////////////////////////////////////////////////////////////

        // Require the new lender to buy the old lender out.
        weth.safeTransferFrom(newTermsData.lender, msg.sender, debt);

        borrowData.termsHash = newTermsHash; // Update the terms hash.
    }

    function kickoffRefinancingAuction(bytes32 borrowHash) external {
        // Ensure the caller is the lender.
        require(msg.sender == getLoanTerms[getBorrowData[borrowHash].termsHash].lender, "NOT_LENDER");

        // Ensure a refinancing auction is not already active.
        require(getAuctionStartBlock[borrowHash] == 0, "AUCTION_ALREADY_STARTED");

        getAuctionStartBlock[borrowHash] = block.number; // Set the auction start.
    }

    function auctionRefinance(bytes32 borrowHash, bytes32 newTermsHash) external {
        // Cache the start block of the refinancing auction.
        uint256 start = getAuctionStartBlock[borrowHash];

        // Ensure an auction is actually active.
        require(start > 0, "NO_ACTIVE_AUCTION");

        // Get the borrow data associated with the hash.
        BorrowData storage borrowData = getBorrowData[borrowHash];

        // Cache the terms hash associated with the borrow data.
        bytes32 termsHash = borrowData.termsHash;

        // Get the terms associated with the borrow.
        LoanTerms memory termsData = getLoanTerms[termsHash];

        // Get the new terms that will be used for refinancing.
        LoanTerms memory newTermsData = getLoanTerms[newTermsHash];

        // Ensure the new terms exist and are not expired.
        require(checkTermsNotExpired(newTermsData), "TERMS_EXPIRED_OR_DO_NOT_EXIST");

        // Calculate the amount of debt associated with the borrow.
        uint256 debt =
            computeCurrentDebt(borrowData.lastTouchedTime, borrowData.lastComputedDebt, termsData.interestRateBips);

        // Ensure the amount being borrowed is within the min and max set in the terms.
        require(debt >= newTermsData.minAmount && debt <= newTermsData.maxAmount, "INVALID_AMOUNT");

        // Calculate the current rate at which the dutch auction would close at.
        uint256 r = calcAuctionRate(start, termsData.liquidationDurationBlocks, termsData.interestRateBips);

        // Ensure the rate is below the liquidation threshold.
        require(r < LIQ_THRESHOLD, "INSOLVENT");

        ///////////////////////////////////////////////////////////

        // Overwrite the old terms's interest rate for use in the checkTermsFavorable
        // computation. That way checkTermsFavorable will enforce that the rate is no
        // worse than the current dutch auction rate.
        termsData.interestRateBips = uint32(r);

        // Ensure the terms are favorable.
        require(checkTermsFavorable(termsData, newTermsData), "TERMS_NOT_FAVORABLE");

        // Lower the consumption amount of the original terms by the debt.
        getTotalAmountConsumed[termsHash] -= debt;

        // Increase the consumed amount of the new terms by the debt, or revert if exceeds the capacity.
        require(newTermsData.totalAmount >= (getTotalAmountConsumed[newTermsHash] += debt), "NEW_TERMS_AT_CAPACITY");

        ///////////////////////////////////////////////////////////

        // Require the new lender to buy the old lender out.
        weth.safeTransferFrom(msg.sender, termsData.lender, debt);

        // Update the debt calculation variables to account for the new rate.
        borrowData.lastComputedDebt = uint96(debt);
        borrowData.lastTouchedTime = uint40(block.timestamp);

        delete getAuctionStartBlock[borrowHash]; // Mark the auction as completed.
    }

    function liquidate(bytes32 borrowHash) external {
        // Cache the start block of the refinancing auction.
        uint256 start = getAuctionStartBlock[borrowHash];

        // Ensure an auction is actually active.
        require(start > 0, "NO_ACTIVE_AUCTION");

        // Get the borrow data associated with the hash.
        BorrowData storage borrowData = getBorrowData[borrowHash];

        // Cache the terms hash associated with the borrow data.
        LoanTerms memory termsData = getLoanTerms[borrowData.termsHash];

        // Calculate the current rate at which the dutch auction would close at.
        uint256 r = calcAuctionRate(start, termsData.liquidationDurationBlocks, termsData.interestRateBips);

        // Ensure the rate is above or equal to the liquidation threshold.
        require(r >= LIQ_THRESHOLD, "NOT_INSOLVENT");

        ///////////////////////////////////////////////////////////

        // Send the NFT to the lender.
        termsData.nft.safeTransferFrom(address(this), termsData.lender, borrowData.nftId);

        delete getAuctionStartBlock[borrowHash]; // Mark the auction as completed.
    }

    /*//////////////////////////////////////////////////////////////
                           VALIDATION HELPERS
    //////////////////////////////////////////////////////////////*/

    function checkTermsNotExpired(LoanTerms memory terms) internal view returns (bool) {
        return terms.deadline >= block.timestamp && terms.nonce >= getNonce[terms.lender];
    }

    function checkTermsFavorable(LoanTerms memory terms1, LoanTerms memory terms2) internal pure returns (bool) {
        return terms2.nft == terms1.nft && terms2.minAmount >= terms1.minAmount
            && terms2.liquidationDurationBlocks >= terms1.liquidationDurationBlocks
            && terms2.interestRateBips <= terms1.interestRateBips;
    }

    /*//////////////////////////////////////////////////////////////
                              HASH HELPERS
    //////////////////////////////////////////////////////////////*/

    function hashLoanTerms(LoanTerms memory l) public view returns (bytes32) {
        return keccak256(abi.encode(l));
    }

    function hashBorrowData(BorrowData memory b) public view returns (bytes32) {
        return keccak256(abi.encode(b));
    }

    /*//////////////////////////////////////////////////////////////
                           CALCULATION HELPERS
    //////////////////////////////////////////////////////////////*/

    function computeCurrentDebt(uint40 lastTouchedTime, uint96 lastComputedDebt, uint32 bips)
        public
        view
        returns (uint256)
    {
        int256 yearsWad = wadDiv(int256(block.timestamp - uint256(lastTouchedTime)) * 1e18, YEAR_WAD);

        return uint256(wadMul(int256(uint256(lastComputedDebt)), wadExp(wadMul(yearsWad, bipsToSignedWads(bips)))));
    }

    // https://www.desmos.com/calculator/7ef4rtuzsh
    function calcAuctionRate(uint256 startBlock, uint32 durBlocks, uint32 oldRate) internal view returns (uint256) {
        int256 logOldRate = wadLn(bipsToSignedWads(oldRate));

        int256 a = wadMul(wadDiv(2e18, int256(uint256(durBlocks) * 1e18)), WAD_LOG_LIQ_THRESHOLD - logOldRate);

        int256 b = WAD_LOG_LIQ_THRESHOLD - (2 * logOldRate);

        return signedWadsToBips(wadExp(wadMul(a, int256(uint256(block.number - startBlock) * 1e18)) - b));
    }

    function bipsToSignedWads(uint256 bips) internal pure returns (int256) {
        return int256((bips * 1e18) / 10000);
    }

    function signedWadsToBips(int256 wads) internal pure returns (uint256) {
        return uint256((wads * 10000) / 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                              EIP-712 LOGIC
    //////////////////////////////////////////////////////////////*/

    function getDomainSeparator() public view virtual returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    function computeDomainSeparator() internal view virtual returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Puree"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }
}
