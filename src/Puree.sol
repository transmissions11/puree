// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "solmate/tokens/ERC721.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";
import "solmate/utils/SignedWadMath.sol";

import "forge-std/console2.sol";

// TODO: How to revoke loan offer once submitted?

/// @dev Stores the data associated with a loan terms offer.
/// @param lender The address of the lender.
/// @param nft The address of the NFT contract the lender is willing to accept as collateral.
/// @param maxAmount The maximum amount of tokens that can be borrowed for 1 collateral unit.
/// @param minAmount The minimum amount of tokens that can be borrowed for 1 collateral unit.
/// @param totalAmount The total amount of tokens that can be borrowed across all borrows associated with these terms.
/// @param liquidationDurationBlocks The duration of the refinancing/liquidation auction in blocks.
/// @param interestRateBips The yearly interest rate of the loan in integer basis points.
/// @param deadline The deadline after which no new loans can be opened against this offer.
/// @param nonce The nonce of the loan terms offer, used to enable bulk canceling term offers.
struct LoanTerms {
    address lender;
    ERC721 nft;
    uint96 maxAmount;
    uint96 minAmount;
    uint96 totalAmount;
    uint16 liquidationDurationBlocks;
    uint32 interestRateBips;
    uint40 deadline;
    uint32 nonce;
}

/// @dev Stores the data associated with a borrow.
/// @param termsHash The hash of the terms the borrow is associated with.
/// @param borrower The address of the borrower.
/// @param nftId The ID of the NFT used as collateral.
/// @param lastComputedDebt The last computed debt of the borrow.
/// @param lastTouchedTime The last time the borrow was touched.
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

    /// @notice Submit valid signed loan terms to the Puree contract.
    /// @param terms The loan terms.
    /// @param v A fragment of the terms' lender's ECDSA signature.
    /// @param r A fragment of the terms' lender's ECDSA signature.
    /// @param s A fragment of the terms' lender's ECDSA signature.
    /// @return termsHash The hash of the terms.
    function submitTerms(LoanTerms calldata terms, uint8 v, bytes32 r, bytes32 s) public returns (bytes32 termsHash) {
        termsHash = hashLoanTerms(terms); // Compute what the terms' hash is going to be.

        // Check the lender listed in the terms has signed the hash.
        require(ecrecover(computeTermsDigest(terms), v, r, s) == terms.lender, "INVALID_SIGNATURE");

        // Check the terms are not already submitted.
        require(getLoanTerms[termsHash].deadline == 0, "TERMS_ALREADY_EXISTS");

        // Check the terms are not expired.
        require(checkTermsNotExpired(terms), "TERMS_EXPIRED");

        getLoanTerms[termsHash] = terms; // Store the terms.
    }

    /// @notice Compute the term's hash digest for EIP-712 signing.
    /// @param terms The loan terms.
    function computeTermsDigest(LoanTerms calldata terms) public view returns (bytes32) {
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

    /// @notice Submit valid signed loan terms to the Puree contract and borrow against them atomically.
    /// @param terms The loan terms.
    /// @param v A fragment of the terms' lender's ECDSA signature.
    /// @param r A fragment of the terms' lender's ECDSA signature.
    /// @param s A fragment of the terms' lender's ECDSA signature.
    /// @param nftId The NFT ID to borrow against.
    function submitTermsAndBorrow(LoanTerms calldata terms, uint8 v, bytes32 r, bytes32 s, uint256 nftId, uint96 amt)
        external
    {
        bytes32 termsHash = submitTerms(terms, v, r, s); // Submit the terms.
        newBorrow(termsHash, nftId, amt); // Borrow against the terms.
    }

    /// @notice Borrow against a a loan terms offer.
    /// @param termsHash The hash of the terms to borrow against.
    /// @param nftId The NFT id to use as collateral.
    /// @param amt The amount to borrow.
    /// @return borrowHash The hash of the borrow data.
    function newBorrow(bytes32 termsHash, uint256 nftId, uint96 amt) public returns (bytes32 borrowHash) {
        // Get the terms associated with the hash.
        LoanTerms memory termsData = getLoanTerms[termsHash];

        // Check the terms exist and are not expired.
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

    /// @notice Further a borrow by adding more debt to it.
    /// @param borrowHash The hash of the borrow data.
    /// @param amt The amount to further the borrow by.
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

    /// @notice Repay a borrow by returning the debt to the lender.
    /// @param borrowHash The hash of the borrow data.
    /// @param amt The amount to repay.
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
                        INSTANT REFINANCING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows a lender to exit a loan by matching it with a new, favorable, offer.
    /// @param borrowHash The hash of the borrow data.
    /// @param newTermsHash The hash of the new terms.
    function instantLenderRefinance(bytes32 borrowHash, bytes32 newTermsHash) external {
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
        require(
            termsData.nft == termsData.nft && newTermsData.minAmount >= termsData.minAmount
                && newTermsData.liquidationDurationBlocks >= termsData.liquidationDurationBlocks
                && newTermsData.interestRateBips <= termsData.interestRateBips,
            "TERMS_NOT_FAVORABLE"
        );

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

    /// @notice Allows a borrower to refinance their loan by selecting a new, favorable, offer.
    /// @param borrowHash The hash of the borrow data.
    /// @param newTermsHash The hash of the new terms.
    function instantBorrowerRefinance(bytes32 borrowHash, bytes32 newTermsHash) external {
        // TODO: Impl or just make people use flashloans?
    }

    /*//////////////////////////////////////////////////////////////
                        AUCTION REFINANCING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows a lender to start a refinancing auction.
    /// @param borrowHash The hash of the borrow data.
    function kickoffRefinancingAuction(bytes32 borrowHash) external {
        // Ensure the caller is the lender.
        require(msg.sender == getLoanTerms[getBorrowData[borrowHash].termsHash].lender, "NOT_LENDER");

        // Ensure a refinancing auction is not already active.
        require(getAuctionStartBlock[borrowHash] == 0, "AUCTION_ALREADY_STARTED");

        getAuctionStartBlock[borrowHash] = block.number; // Set the auction start.
    }

    /// @notice Allows a bidder (or anyone) to settle a refinancing auction by providing a favorable offer.
    /// @param borrowHash The hash of the borrow data.
    /// @param newTermsHash The hash of the new terms.
    function settleRefinancingAuction(bytes32 borrowHash, bytes32 newTermsHash) external {
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
        uint256 r = calcRefinancingAuctionRate(start, termsData.liquidationDurationBlocks, termsData.interestRateBips);

        // Ensure the rate is below the liquidation threshold.
        require(r < LIQ_THRESHOLD, "INSOLVENT");

        ///////////////////////////////////////////////////////////

        // Overwrite the old terms's interest rate for use in the checkTermsFavorable
        // computation. That way checkTermsFavorable will enforce that the rate is no
        // worse than the current dutch auction rate.
        termsData.interestRateBips = uint32(r);

        // Ensure the terms are reasonable.
        require(
            termsData.nft == termsData.nft && newTermsData.minAmount >= termsData.minAmount
                && newTermsData.liquidationDurationBlocks >= termsData.liquidationDurationBlocks
                && r <= termsData.interestRateBips, // Check against the current auction-set rate
            "TERMS_NOT_REASONABLE"
        );

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

    /// @notice Allows a lender to seize a borrower's NFT if they are insolvent.
    /// @param borrowHash The hash of the borrow data.
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
        uint256 r = calcRefinancingAuctionRate(start, termsData.liquidationDurationBlocks, termsData.interestRateBips);

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

    /// @dev Checks a terms offer is not expired.
    /// @param terms The terms to check.
    function checkTermsNotExpired(LoanTerms memory terms) internal view returns (bool) {
        return terms.deadline >= block.timestamp && terms.nonce >= getNonce[terms.lender];
    }

    /*//////////////////////////////////////////////////////////////
                              HASH HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Hashes terms data.
    /// @param l The terms data to hash.
    function hashLoanTerms(LoanTerms memory l) public view returns (bytes32) {
        return keccak256(abi.encode(l));
    }

    /// @dev Hashes borrow data.
    /// @param b The borrow data to hash.
    function hashBorrowData(BorrowData memory b) public view returns (bytes32) {
        return keccak256(abi.encode(b));
    }

    /*//////////////////////////////////////////////////////////////
                           CALCULATION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Computes the current debt of a borrow given the last time it was touched and the last computed debt.
    /// @param lastTouchedTime The last time the debt was touched.
    /// @param lastComputedDebt The last computed debt.
    /// @param bips The yearly interest rate bips.
    function computeCurrentDebt(uint40 lastTouchedTime, uint96 lastComputedDebt, uint32 bips)
        public
        view
        returns (uint256)
    {
        int256 yearsWad = wadDiv(int256(block.timestamp - uint256(lastTouchedTime)) * 1e18, YEAR_WAD);

        return uint256(wadMul(int256(uint256(lastComputedDebt)), wadExp(wadMul(yearsWad, bipsToSignedWads(bips)))));
    }

    /// @dev Calculates the current maximum interest rate a specific refinancing
    /// auction could settle at currently given the auction's start block and duration.
    /// @param startBlock The block the auction started at.
    /// @param durBlocks The duration of the auction in blocks.
    function calcRefinancingAuctionRate(uint256 startBlock, uint32 durBlocks, uint32 oldRate)
        internal
        view
        returns (uint256)
    {
        int256 logOldRate = wadLn(bipsToSignedWads(oldRate));

        int256 a = wadMul(wadDiv(2e18, int256(uint256(durBlocks) * 1e18)), WAD_LOG_LIQ_THRESHOLD - logOldRate);

        int256 b = WAD_LOG_LIQ_THRESHOLD - (2 * logOldRate);

        return signedWadsToBips(wadExp(wadMul(a, int256(uint256(block.number - startBlock) * 1e18)) - b));
    }

    /// @dev Converts an integer bips value to a signed wad value.
    function bipsToSignedWads(uint256 bips) internal pure returns (int256) {
        return int256((bips * 1e18) / 10000);
    }

    /// @dev Converts a signed wad value to an integer bips value.
    function signedWadsToBips(int256 wads) internal pure returns (uint256) {
        return uint256((wads * 10000) / 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                              EIP-712 LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the current EIP-712 domain separator.
    function getDomainSeparator() public view virtual returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : computeDomainSeparator();
    }

    /// @dev Computes the most up to date EIP-712 domain separator.
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
