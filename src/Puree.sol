// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "solmate/tokens/ERC721.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";
import "solmate/utils/SignedWadMath.sol";

/// @dev Stores the data associated with a loan offer.
/// @param terms The terms associated with the loan.
/// @param deadline The deadline after which no new loans can be opened against this offer.
/// @param nonce The nonce of the loan terms offer, used to enable bulk canceling term offers.
struct Offer {
    Terms terms;
    uint40 deadline;
    uint32 nonce;
}

/// @dev Stores the data associated with a set of loan terms.
/// @param lender The address of the lender.
/// @param nft The address of the NFT contract the lender is willing to accept as collateral.
/// @param maxAmount The maximum amount of tokens that can be borrowed for 1 collateral unit.
/// @param minAmount The minimum amount of tokens that can be borrowed for 1 collateral unit.
/// @param totalAmount The total amount of tokens that can be borrowed across all borrows associated with these terms.
/// @param liquidationDurationBlocks The duration of the refinancing/liquidation auction in blocks.
/// @param interestRateBips The yearly interest rate of the loan in integer basis points.
struct Terms {
    address lender;
    ERC721 nft;
    uint96 maxAmount;
    uint96 minAmount;
    uint96 totalAmount;
    uint16 liquidationDurationBlocks;
    uint32 interestRateBips;
}

/// @dev Stores the data associated with a borrow.
/// @param termsHash The hash of the terms the borrow is associated with.
/// @param borrower The address of the borrower.
/// @param nftId The ID of the NFT used as collateral.
/// @param lastComputedDebt The last computed debt of the borrow.
/// @param lastTouchedTime The last time the borrow was touched.
struct Borrow {
    Terms terms;
    address borrower;
    uint256 nftId;
    uint96 lastComputedDebt;
    uint40 lastTouchedTime;
    uint40 auctionStartBlock;
}

/// @title Puree — A Blend implementation.
/// @author Galaga, Pacman, Dan Robinson, t11s
contract Puree {
    using SafeTransferLib for ERC20;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    ERC20 internal immutable weth;

    uint256 internal immutable INITIAL_CHAIN_ID;

    bytes32 internal immutable INITIAL_DOMAIN_SEPARATOR;

    constructor(ERC20 _weth) {
        weth = _weth;

        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = computeDomainSeparator();
    }

    /*//////////////////////////////////////////////////////////////
                                LOAN DATA
    //////////////////////////////////////////////////////////////*/

    /// @notice The value of the next borrow id.
    uint256 public nextBorrowId = 1;

    /// @notice Maps borrow ids to the hash of their data.
    mapping(uint256 => bytes32) public getBorrowHash;

    /// @notice Maps terms hashes to the total amount
    // of their offered collateral currently borrowed.
    mapping(bytes32 => uint256) public getTotalAmountOfTermsConsumed;

    /*//////////////////////////////////////////////////////////////
                                USER DATA
    //////////////////////////////////////////////////////////////*/

    /// @notice Maps users to their current nonce,
    /// used to enable bulk canceling of loan offers.
    mapping(address => uint256) public getNonce;

    /// @notice Allows a user to bump their nonce by a given amount.
    /// @param n The amount to bump the nonce by.
    function bumpNonce(uint256 n) external {
        getNonce[msg.sender] += n;
    }

    /*//////////////////////////////////////////////////////////////
                               LOAN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Borrow against a loan offer.
    /// @param offer The loan offer to borrow against.
    /// @param v A fragment of the lender's ECDSA signature.
    /// @param r A fragment of the lender's ECDSA signature.
    /// @param s A fragment of the lender's ECDSA signature.
    /// @param nftId The NFT id to use as collateral.
    /// @param amt The amount to borrow.
    /// @return borrowId The id assigned to the borrow.
    function newBorrow(Offer calldata offer, uint8 v, bytes32 r, bytes32 s, uint256 nftId, uint96 amt)
        public
        validateOffer(offer, v, r, s)
        returns (uint256 borrowId)
    {
        // Get and cache a pointer to the terms.
        Terms calldata terms = offer.terms;

        // Ensure the amount being borrowed is within the min and max set in the terms.
        require(amt <= terms.maxAmount && amt >= terms.minAmount, "INVALID_AMOUNT");

        // Ensure the terms still have dry powder associated with them.
        require(
            terms.totalAmount >= (getTotalAmountOfTermsConsumed[keccak256(abi.encode(terms))] += amt), "AT_CAPACITY"
        );

        ///////////////////////////////////////////////////////////////////

        // Take the borrower's collateral NFT and keep it in the Puree contract for safe keeping.
        terms.nft.transferFrom(msg.sender, address(this), nftId);

        // Give the borrower the amount of debt they've requested.
        weth.safeTransferFrom(terms.lender, msg.sender, amt);

        ///////////////////////////////////////////////////////////////////

        getBorrowHash[borrowId = nextBorrowId++] = keccak256(
            abi.encode(
                Borrow({
                    terms: terms,
                    borrower: msg.sender,
                    nftId: nftId,
                    lastComputedDebt: amt,
                    lastTouchedTime: uint40(block.timestamp),
                    auctionStartBlock: 0
                })
            )
        );
    }

    /// @notice Further a borrow by adding more debt to it.
    /// @param borrow The borrow data.
    /// @param borrowId The id assigned to the borrow.
    /// @param amt The amount to further the borrow by.
    function furtherBorrow(Borrow calldata borrow, uint256 borrowId, uint256 amt)
        external
        validateBorrow(borrow, borrowId)
    {
        // Get and cache a pointer to the terms.
        Terms calldata terms = borrow.terms;

        // Ensure the caller is the borrower.
        require(msg.sender == borrow.borrower, "NOT_BORROWER");

        // Calculate the amount of debt associated with the borrow.
        uint256 debt = computeCurrentDebt(borrow.lastTouchedTime, borrow.lastComputedDebt, terms.interestRateBips);

        // Calculate the amount of debt associated with the borrow after furthering.
        uint256 newDebt = debt + amt;

        ///////////////////////////////////////////////////////////////////

        // Ensure the new debt is within the max set in the terms.
        require(newDebt <= borrow.terms.maxAmount, "INVALID_AMOUNT");

        // Ensure the offer terms still have dry powder associated with them.
        require(
            terms.totalAmount >= (getTotalAmountOfTermsConsumed[keccak256(abi.encode(terms))] += amt), "AT_CAPACITY"
        );

        ///////////////////////////////////////////////////////////////////

        // Give the borrower the amount of collateral they've requested.
        weth.safeTransferFrom(terms.lender, msg.sender, amt);

        ////////////////////////////////////////////////////////////////////

        getBorrowHash[borrowId] = keccak256(
            abi.encode(
                Borrow({
                    terms: terms,
                    borrower: borrow.borrower,
                    nftId: borrow.nftId,
                    lastComputedDebt: uint96(newDebt),
                    lastTouchedTime: uint40(block.timestamp),
                    auctionStartBlock: borrow.auctionStartBlock
                })
            )
        );
    }

    /// @notice Repay a borrow by returning the debt to the lender.
    /// @param borrow The borrow data.
    /// @param borrowId The id assigned to the borrow.
    /// @param amt The amount to repay.
    function repay(Borrow calldata borrow, uint256 borrowId, uint96 amt) external validateBorrow(borrow, borrowId) {
        // Get and cache a pointer to the terms.
        Terms calldata terms = borrow.terms;

        // Cache the terms hash associated with the terms.
        bytes32 termsHash = keccak256(abi.encode(terms));

        // Get the total amount of the offer terms consumed.
        uint256 consumed = getTotalAmountOfTermsConsumed[termsHash];

        // Calculate the amount of debt associated with the borrow.
        uint256 debt = computeCurrentDebt(borrow.lastTouchedTime, borrow.lastComputedDebt, terms.interestRateBips);

        // If the user has specified a max amount, they want to repay in full.
        if (amt == type(uint96).max) amt = uint96(debt);

        // Calculate the amount of debt associated with the borrow after repayment.
        uint256 newDebt = debt - amt;

        /////////////////////////////////////////////////////////

        unchecked {
            // Lower the amount consumed by the amount being repaid,
            // ensuring not to underflow if consumption would be lowered below 0.
            getTotalAmountOfTermsConsumed[termsHash] = consumed > amt ? consumed - amt : 0;
        }

        //////////////////////////////////////////////////////

        // Send the lender the repayment.
        weth.safeTransferFrom(msg.sender, terms.lender, amt);

        // If the user now has no remaining debt:
        if (newDebt == 0) {
            // Give them their NFT back.
            terms.nft.transferFrom(address(this), borrow.borrower, borrow.nftId);
        }

        ////////////////////////////////////////////////////////////////////

        getBorrowHash[borrowId] = keccak256(
            abi.encode(
                Borrow({
                    terms: terms,
                    borrower: borrow.borrower,
                    nftId: borrow.nftId,
                    lastComputedDebt: uint96(newDebt),
                    lastTouchedTime: uint40(block.timestamp),
                    auctionStartBlock: borrow.auctionStartBlock
                })
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                        INSTANT REFINANCING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows a lender to exit a loan by matching it with a new, favorable, offer.
    /// @param borrow The borrow data.
    /// @param borrowId The id assigned to the borrow.
    /// @param offer The offer data to use for the refinance.
    /// @param v A fragment of the lender's ECDSA signature.
    /// @param r A fragment of the lender's ECDSA signature.
    /// @param s A fragment of the lender's ECDSA signature.
    function instantLenderRefinance(
        Borrow calldata borrow,
        uint256 borrowId,
        Offer calldata offer,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external validateBorrow(borrow, borrowId) validateOffer(offer, v, r, s) {
        {
            // Ensure the caller is the lender.
            require(msg.sender == borrow.terms.lender, "NOT_LENDER");

            // Ensure the new terms are favorable to the borrower.
            require(
                borrow.terms.nft == offer.terms.nft && offer.terms.minAmount <= borrow.terms.minAmount
                    && offer.terms.liquidationDurationBlocks >= borrow.terms.liquidationDurationBlocks
                    && offer.terms.interestRateBips <= borrow.terms.interestRateBips,
                "TERMS_NOT_FAVORABLE"
            );
        }

        ///////////////////////////////////////////////////////////

        // Calculate the amount of debt associated with the borrow.
        uint256 debt =
            computeCurrentDebt(borrow.lastTouchedTime, borrow.lastComputedDebt, borrow.terms.interestRateBips);

        // Ensure the amount being borrowed is within the min and max set in the new terms.
        require(debt >= offer.terms.minAmount && debt <= offer.terms.maxAmount, "iNVALID_DEBT_AMOUNT");

        ///////////////////////////////////////////////////////////////

        {
            // Cache the terms hash associated with the terms.
            bytes32 oldTermsHash = keccak256(abi.encode(borrow.terms));
            bytes32 newTermsHash = keccak256(abi.encode(offer.terms));

            // Lower the consumption amount of the original terms by the debt.
            getTotalAmountOfTermsConsumed[oldTermsHash] -= debt;

            // Increase the consumed amount of the new terms by the debt, or revert if exceeds the capacity.
            require(offer.terms.totalAmount >= (getTotalAmountOfTermsConsumed[newTermsHash] += debt), "AT_CAPACITY");
        }

        ///////////////////////////////////////////////////////////////

        // Require the new lender to buy the old lender out.
        weth.safeTransferFrom(offer.terms.lender, msg.sender, debt);

        ///////////////////////////////////////////////////////////////

        getBorrowHash[borrowId] = keccak256(
            abi.encode(
                Borrow({
                    terms: offer.terms,
                    borrower: borrow.borrower,
                    nftId: borrow.nftId,
                    lastComputedDebt: uint96(debt),
                    lastTouchedTime: uint40(block.timestamp),
                    auctionStartBlock: borrow.auctionStartBlock
                })
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                        AUCTION REFINANCING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows a lender to start a refinancing auction on a borrow.
    /// @param borrow The borrow data.
    /// @param borrowId The id assigned to the borrow.
    function kickoffRefinancingAuction(Borrow calldata borrow, uint256 borrowId)
        external
        validateBorrow(borrow, borrowId)
    {
        // Get and cache a pointer to the terms.
        Terms calldata terms = borrow.terms;

        // Ensure the caller is the lender.
        require(msg.sender == terms.lender, "NOT_LENDER");

        // Ensure a refinancing auction is not already active.
        require(borrow.auctionStartBlock == 0, "AUCTION_ALREADY_STARTED");

        ////////////////////////////////////////////////////////////////////

        getBorrowHash[borrowId] = keccak256(
            abi.encode(
                Borrow({
                    terms: terms,
                    borrower: borrow.borrower,
                    nftId: borrow.nftId,
                    lastComputedDebt: borrow.lastComputedDebt,
                    lastTouchedTime: borrow.lastTouchedTime,
                    auctionStartBlock: uint40(block.number)
                })
            )
        );
    }

    /// @notice Allows a bidder (or anyone) to settle a refinancing auction by providing a favorable offer.
    /// @param borrow The borrow data.
    /// @param borrowId The id assigned to the borrow.
    /// @param offer The offer data to use for the refinance.
    /// @param v A fragment of the lender's ECDSA signature.
    /// @param r A fragment of the lender's ECDSA signature.
    /// @param s A fragment of the lender's ECDSA signature.
    function settleRefinancingAuction(
        Borrow calldata borrow,
        uint256 borrowId,
        Offer calldata offer,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external validateBorrow(borrow, borrowId) validateOffer(offer, v, r, s) {
        {
            // Ensure an auction is actually active.
            require(borrow.auctionStartBlock > 0, "NO_ACTIVE_AUCTION");

            // Calculate the current rate at which the dutch auction would close at.
            uint256 newInterestRateBips = calcRefinancingAuctionRate(
                borrow.auctionStartBlock, borrow.terms.liquidationDurationBlocks, borrow.terms.interestRateBips
            );

            // Ensure the rate is below the liquidation threshold.
            require(newInterestRateBips < LIQ_THRESHOLD, "INSOLVENT");

            // Ensure the terms are reasonable.
            require(
                borrow.terms.nft == offer.terms.nft && offer.terms.minAmount <= borrow.terms.minAmount
                    && offer.terms.liquidationDurationBlocks >= borrow.terms.liquidationDurationBlocks
                    && offer.terms.interestRateBips <= newInterestRateBips,
                "TERMS_NOT_REASONABLE"
            );
        }

        ///////////////////////////////////////////////////////////

        // Calculate the amount of debt associated with the borrow.
        uint256 debt =
            computeCurrentDebt(borrow.lastTouchedTime, borrow.lastComputedDebt, borrow.terms.interestRateBips);

        // Ensure the amount being borrowed is within the min and max set in the new terms.
        require(debt >= offer.terms.minAmount && debt <= offer.terms.maxAmount, "INVALID_AMOUNT");

        ///////////////////////////////////////////////////////////

        {
            // Cache the terms hash associated with the terms.
            bytes32 oldTermsHash = keccak256(abi.encode(borrow.terms));
            bytes32 newTermsHash = keccak256(abi.encode(offer.terms));

            // Lower the consumption amount of the original terms by the debt.
            getTotalAmountOfTermsConsumed[oldTermsHash] -= debt;

            // Increase the consumed amount of the new terms by the debt, or revert if exceeds the capacity.
            require(offer.terms.totalAmount >= (getTotalAmountOfTermsConsumed[newTermsHash] += debt), "AT_CAPACITY");
        }

        ///////////////////////////////////////////////////////////

        // Require the new lender to buy the old lender out.
        weth.safeTransferFrom(offer.terms.lender, borrow.terms.lender, debt);

        ///////////////////////////////////////////////////////////

        getBorrowHash[borrowId] = keccak256(
            abi.encode(
                Borrow({
                    terms: offer.terms,
                    borrower: borrow.borrower,
                    nftId: borrow.nftId,
                    lastComputedDebt: uint96(debt),
                    lastTouchedTime: uint40(block.timestamp),
                    auctionStartBlock: 0 // Reset the auction start block.
                })
            )
        );
    }

    /// @notice Allows a lender to seize a borrower's NFT if they are insolvent.
    /// @param borrow The borrow data.
    /// @param borrowId The id assigned to the borrow.
    function liquidate(Borrow calldata borrow, uint256 borrowId) external validateBorrow(borrow, borrowId) {
        // Get and cache a pointer to the terms.
        Terms calldata terms = borrow.terms;

        // Ensure an auction is actually active.
        require(borrow.auctionStartBlock > 0, "NO_ACTIVE_AUCTION");

        // Calculate the current rate at which the dutch auction would close at.
        uint256 newInterestRateBips = calcRefinancingAuctionRate(
            borrow.auctionStartBlock, terms.liquidationDurationBlocks, terms.interestRateBips
        );

        // Ensure the rate is above or equal to the liquidation threshold.
        require(newInterestRateBips >= LIQ_THRESHOLD, "NOT_INSOLVENT");

        ///////////////////////////////////////////////////////////

        // Send the NFT to the lender.
        terms.nft.safeTransferFrom(address(this), terms.lender, borrow.nftId);

        ///////////////////////////////////////////////////////////

        getBorrowHash[borrowId] = keccak256(
            abi.encode(
                Borrow({
                    terms: terms,
                    borrower: borrow.borrower,
                    nftId: borrow.nftId,
                    lastComputedDebt: borrow.lastComputedDebt,
                    lastTouchedTime: borrow.lastTouchedTime,
                    auctionStartBlock: 0 // Reset the auction start block.
                })
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                            CALCULATION HELPERS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant LIQ_THRESHOLD = 100_000;

    int256 internal constant YEAR_WAD = 365 days * 1e18;

    int256 internal immutable WAD_LOG_LIQ_THRESHOLD = wadLn(bipsToSignedWads(LIQ_THRESHOLD));

    /// @dev Computes the current debt of a borrow given the last time it was touched and the last computed debt.
    /// @param lastTouchedTime The last time the debt was touched.
    /// @param lastComputedDebt The last computed debt.
    /// @param bips The yearly interest rate bips.
    /// @dev Formula: https://www.desmos.com/calculator/l6omp0rwnh
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
    /// @dev Formula: https://www.desmos.com/calculator/7ef4rtuzsh
    function calcRefinancingAuctionRate(uint256 startBlock, uint32 durBlocks, uint32 oldRate)
        public
        view
        returns (uint256)
    {
        int256 logOldRate = wadLn(bipsToSignedWads(oldRate));

        int256 a = wadMul(wadDiv(2e18, int256(uint256(durBlocks) * 1e18)), WAD_LOG_LIQ_THRESHOLD - logOldRate);

        int256 b = WAD_LOG_LIQ_THRESHOLD - (2 * logOldRate);

        // We add 1 because otherwise rounding errors and truncation mean we will be off by 1 from LIQ_THRESHOLD by the end.
        return signedWadsToBips(wadExp(wadMul(a, int256(uint256(block.number - startBlock) * 1e18)) - b)) + 1;
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

    bytes32 public constant TERMS_TYPEHASH = keccak256(
        "TermsOffer(address lender,address nft,uint96 maxAmount,uint96 minAmount,uint96 totalAmount,uint16 liquidationDurationBlocks,uint32 interestRateBips,uint40 deadline,uint32 nonce)"
    );

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

    /// @notice Compute an offer's hash digest for EIP-712 signing.
    function computeOfferDigest(Offer calldata offer) public view returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                "\x19\x01",
                getDomainSeparator(),
                keccak256(
                    abi.encode(
                        TERMS_TYPEHASH,
                        offer.terms.lender,
                        offer.terms.nft,
                        offer.terms.maxAmount,
                        offer.terms.minAmount,
                        offer.terms.totalAmount,
                        offer.terms.liquidationDurationBlocks,
                        offer.terms.interestRateBips,
                        offer.deadline,
                        offer.nonce
                    )
                )
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                           VALIDATION MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier validateOffer(Offer calldata offer, uint8 v, bytes32 r, bytes32 s) {
        // Check the lender listed in the terms has signed the hash.
        require(ecrecover(computeOfferDigest(offer), v, r, s) == offer.terms.lender, "INVALID_OFFER_SIGNATURE");

        // Check we are not past the offer's deadline and the lender's nonce has not been bumped past the offer's.
        require(offer.deadline >= block.timestamp && offer.nonce >= getNonce[offer.terms.lender], "OFFER_EXPIRED");

        _;
    }

    modifier validateBorrow(Borrow calldata borrow, uint256 borrowId) {
        require(getBorrowHash[borrowId] == keccak256(abi.encode(borrow)), "INVALID_BORROW_PREIMAGE");

        _;
    }
}
