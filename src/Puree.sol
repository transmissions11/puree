// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "solmate/tokens/ERC721.sol";
import "solmate/tokens/ERC20.sol";
import "solmate/utils/SafeTransferLib.sol";
import "solmate/utils/SignedWadMath.sol";

// Blend: Peer-to-Peer Perpetual Lending With Arbitrary Collateral
// Galaga, Pacman, Dan Robinson

// Introduction
// This paper introduces Blend: a peer-to-peer perpetual lending protocol that supports arbitrary collateral, including NFTs. Blend has no oracle dependencies and no expiries, allowing borrowing positions to remain open indefinitely until liquidated, with market-determined interest rates.
// Blend matches users who want to borrow against their non-fungible collateral with whatever lender is willing to offer the most competitive rate, using a sophisticated off-chain order protocol.
// By default, Blend loans have fixed rates and never expire. Borrowers can repay at any time, while lenders can exit their positions by triggering a Dutch auction to find a new lender at a new rate. If that auction fails, the borrower is liquidated and the lender takes possession of the collateral.

// Tradeoffs and differences from prior work
// There has been a significant amount of prior work done on NFT-backed lending. Popular models include perp-like protocols (such as Floor Perps and papr), pooled lending protocols (such as BendDAO and Astaria), and peer-to-peer protocols (such as NFTfi and Backed).

// Blend most resembles the peer-to-peer model, but has some important differences. Rather than exhaustively examining the details of these individual protocols, we will describe some common design decisions and how Blend differs.

// Oracles
// Some of these protocols require an oracle, either for liquidations or to determine an interest rate. But individual NFT prices are very difficult to measure objectively. Even floor prices tend to be difficult to measure on-chain. Solutions often involve a trusted party, or are manipulable with trading strategies.

// Blend avoids any oracle dependencies in the core protocol. Liquidations are triggered by the failure of a Dutch auction.

// Expiries
// Some protocols only support expiring debt positions. This is inconvenient for borrowers, who need to remember to close or roll their positions before expiry (or risk harsh penalties such as confiscation of their NFT). The process of manually rolling these positions also costs gas, which cuts into the yield from lending.

// Blend automatically rolls borrows for as long as any lender is willing to lend against it. On-chain transactions are only needed when interest rates change or lenders want to exit the position.

// Liquidations
// Some protocols do not support liquidations before expiry. This is convenient for borrowers, and makes sense for many use cases. But because this effectively gives borrowers an embedded put option, lenders demand short expirations, high interest rates and/or low loan-to-value ratios to compensate for the risk of undercollateralization.

// In Blend, an NFT may be liquidated whenever a lender triggers one and nobody is willing to take over the debt at any interest rate.

// Pooled lending
// Some protocols pool lenders’ funds together and attempt to manage risk for them. This often means leaning heavily on on-chain governance or centralized administrators.

// Blur uses a peer-to-peer model where each loan is matched individually. Instead of optimizing for ease-of-use on the lending side, Blend assumes the existence of more sophisticated lenders capable of participating in complex on- and off-chain protocols, evaluating risks, and using their own capital.

// Constructing the mechanism
// In this section, we motivate the design of the protocol, starting with a simple peer-to-peer fixed-rate lending protocol and adding adaptations to allow gas-efficient rolling and market discovery of floating rates.

// Peer-to-peer fixed-term borrowing
// First, let us imagine how our protocol might work if it had expiring rather than perpetual loans.
// We start with the lender. A lender signs an off-chain offer to lend some principal amount of ETH with a particular interest rate and expiration time, against any NFT of a specified collection. (The offer and off-chain orderbook protocol is discussed in greater detailed in a later section.)
// A borrower has an NFT they want to borrow against. They browse the available off-chain offers and choose the one that matches the terms they’re interested in. They then create an on-chain transaction that fulfills the lender’s offer, puts their NFT in a vault with a lien on it, and transfers the principal from the lender to themselves.
// Before the expiration time, the borrower needs to pay the repayment amount (calculated as the loan amount plus interest) to the lender, which closes their position. Otherwise, the lender can take the collateral.
// Note that the borrower can choose not to repay the loan if the value of the NFT has fallen below the repayment amount.

// Auto-rolling with auction
// In the above mechanism, if the borrower forgets to repay the loan, they lose their NFT, even if the NFT is worth much more than the repayment amount. This seems harsh.
// In many cases, someone else might have been willing to pay the lender the full repayment amount in order to take over the loan going forward, though possibly with a higher rate of interest.
// So instead of simply giving the collateral to the lender, we could have a Dutch auction to extend the loan whenever the borrower fails to repay. The auction would begin at 0% with a steadily rising rate until someone claimed it. The winner would pay the full repayment amount to the lender, calculated as of the moment the auction completes, and take over the loan going forward, using the new interest rate.
// If the collateral is worth close to or less than the repayment amount, it’s possible that nobody would be willing to take over the loan at any interest rate. While it’s impossible to know this for certain, we can guess that once the Dutch auction hits some ridiculous rate (think 10,000%+ APY), that is enough to show that the collateral is insufficient to support the loan. When that happens, the auction “fails” and the lender takes possession of the NFT.

// Optimistic auctions
// In some cases, the same lender might be happy to continue the same loan at the same terms, and the borrower may too. We might even consider that the default case. In that case, it would be wasteful to run the auction.
// Instead, we can choose to have an optimistic protocol where borrowers and lenders, by default, continue with the same terms, extending the expiration time by some predetermined loan period.
// The terms of the loan would only change on some user-initiated action, as described below under “repayment, refinancing, and liquidation.”

// Continuous loans
// One issue with the above protocol is that during a loan period, if the price of the collateral falls dangerously close to the price of the repayment amount, there is no way to liquidate it.
// This is less of an issue if the loan period is very short, since if the lender is concerned about the safety of the collateral, they can trigger a refinancing auction at the next expiry.
// We could imagine shortening the expiry period until it is infinitesimal. If, at any moment, the lender becomes concerned about the safety of the collateral, they could trigger a refinancing auction.
// This lets us drop the concept of expiration times and loan periods. Interest is accumulated continuously and repayment amount is calculated on the fly when needed. All timelines and deadlines during refinancing events can be defined relative to the time the process was initiated.
// In practice, given transaction costs and necessary delays for mechanisms like Dutch auctions, the protocol won’t work exactly like a continuously rolling series of infinitesimal loans, especially during the refinancing auctions themselves.

// User actions
// By default, loans continue indefinitely until some user interacts with the contract. This section describes the actions that lenders, borrowers, or third parties can take to alter loans.

// Loan creation
// A borrower can initiate a loan by submitting a compatible order from some lender to their vault. This is described in greater detail under “Orders” below.

// Repayment
// Suppose the borrower wants to end the loan and get their NFT back. They can repay the current repayment amount to terminate their loan.
// The borrower can also do a partial repayment, shrinking the repayment amount.

// Instant refinancing
// Suppose the lender wants to get out of the loan immediately, and there is an available offer on the orderbook that has the same or better terms.
// The lender can instantly transfer the loan to the other lender by submitting the other lender’s order to the vault. (Note that the borrower can do the same thing by using a flash loan to repay the loan and take out a new one.)

// Auction refinancing
// Suppose the lender wants to get out of the loan.
// The lender can trigger a Dutch auction where anyone is allowed to buy out their loan and take it over. The initial offer would allow anyone to take over the loan at 0%, with the rate rising over time. Once the auction hits an interest rate at which a new lender is interested in lending, they can accept it and take over the loan.
// To do so, someone can submit a transaction with a compatible order, with a principal amount equal to the repayment amount. The new lender would pay the full repayment amount to the previous lender, as of the moment the auction completes.
// Once the auction hits some max rate, the position is considered liquidated. The lender takes possession of the collateral.
// As part of the transaction that triggers the Dutch auction, the lender must also put down a tip. This tip is paid to anyone who submits the transaction that completes the auction (or to the borrower if the loan is repaid). The tip (whose amount is specified in the initial order) should be calibrated to be greater than the gas cost of the transaction that completes the auction, under most conditions. This incentivizes third parties to submit available orders to the chain as soon as they become compatible.

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

    uint256 internal constant LIQ_THRESHOLD = 100_000e18; // TODO

    ERC20 internal immutable weth;

    constructor(ERC20 _weth) {
        weth = _weth;
    }

    /*//////////////////////////////////////////////////////////////
                                LOAN DATA
    //////////////////////////////////////////////////////////////*/

    mapping(bytes32 => LoanTerms) getLoanTerms;

    mapping(bytes32 => BorrowData) getBorrowData;

    // TODO: This could be rolled into terms, but
    // should just be a hash or whatever long term
    mapping(bytes32 => uint256) getTotalAmountConsumed;

    mapping(bytes32 => uint256) getAuctionStartTime;

    /*//////////////////////////////////////////////////////////////
                                USER DATA
    //////////////////////////////////////////////////////////////*/

    mapping(address => uint256) getNonce;

    function bumpNonce(uint256 n) external {
        getNonce[msg.sender] += n;
    }

    /*//////////////////////////////////////////////////////////////
                               TERMS LOGIC
    //////////////////////////////////////////////////////////////*/

    function submitTerms(LoanTerms calldata terms, uint8 v, bytes32 r, bytes32 s) external {
        bytes32 termsHash = hashLoanTerms(terms); // Compute what the terms' hash is going to be.

        // Check the lender listed in the terms has signed the hash.
        require(ecrecover(termsHash, v, r, s) == terms.lender, "INVALID_SIGNATURE");

        // Check the terms are not already submitted.
        require(getLoanTerms[termsHash].deadline == 0, "TERMS_ALREADY_EXISTS");

        // Check the terms are not expired.
        require(checkTermsNotExpired(terms), "TERMS_EXPIRED");

        getLoanTerms[termsHash] = terms; // Store the terms.
    }

    /*//////////////////////////////////////////////////////////////
                               LOAN LOGIC
    //////////////////////////////////////////////////////////////*/

    function newBorrow(bytes32 termsHash, uint256 nftId, uint96 amt) external {
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
        termsData.nft.safeTransferFrom(msg.sender, address(this), nftId);

        // Give the borrower the amount of debt they've requested.
        weth.safeTransferFrom(termsData.lender, msg.sender, amt);

        ///////////////////////////////////////////////////////////////////

        // Create a new borrow data struct with a reference to the terms, the borrower, the nft, the amount, and the time.
        BorrowData memory data = BorrowData(termsHash, msg.sender, nftId, amt, uint40(block.timestamp));

        getBorrowData[hashBorrowData(data)] = data; // Store the borrow data.
    }

    function furtherBorrow(bytes32 borrowHash, uint256 amt) public {
        // Get the borrow data associated with the hash.
        BorrowData storage borrowData = getBorrowData[borrowHash];

        // Cache the terms hash associated with the borrow data.
        bytes32 termsHash = borrowData.termsHash;

        // Get the terms associated with the borrow.
        LoanTerms memory termsData = getLoanTerms[termsHash];

        // Check the terms exist and are not expired
        require(checkTermsNotExpired(termsData), "TERMS_EXPIRED_OR_DO_NOT_EXIST");

        // Calculate the amount of debt associated with the borrow.
        uint256 debt = calcInterest(borrowData.lastTouchedTime, borrowData.lastComputedDebt, termsData.interestRateBips);

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

    function repay(bytes32 borrowHash, uint96 amt) public {
        // Get the borrow data associated with the hash.
        BorrowData storage borrowData = getBorrowData[borrowHash];

        // Cache the terms hash associated with the borrow data.
        bytes32 termsHash = borrowData.termsHash;

        // Get the terms associated with the borrow.
        LoanTerms memory termsData = getLoanTerms[termsHash];

        // Get the total amount of the offer terms consumed.
        uint256 consumed = getTotalAmountConsumed[termsHash];

        // Calculate the amount of debt associated with the borrow.
        uint256 debt = calcInterest(borrowData.lastTouchedTime, borrowData.lastComputedDebt, termsData.interestRateBips);

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
            termsData.nft.safeTransferFrom(address(this), borrowData.borrower, borrowData.nftId);
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
        uint256 debt = calcInterest(borrowData.lastTouchedTime, borrowData.lastComputedDebt, termsData.interestRateBips);

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
        require(getAuctionStartTime[borrowHash] == 0, "AUCTION_ALREADY_STARTED");

        getAuctionStartTime[borrowHash] = block.timestamp; // Set the auction start time.
    }

    function auctionRefinance(bytes32 borrowHash, bytes32 newTermsHash) external {
        // Cache the start time of the refinancing auction.
        uint256 start = getAuctionStartTime[borrowHash];

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
        uint256 debt = calcInterest(borrowData.lastTouchedTime, borrowData.lastComputedDebt, termsData.interestRateBips);

        // Ensure the amount being borrowed is within the min and max set in the terms.
        require(debt >= newTermsData.minAmount && debt <= newTermsData.maxAmount, "INVALID_AMOUNT");

        // Calculate the current rate at which the dutch auction would close at.
        uint256 r = calcAuctionRate(uint40(start), termsData.liquidationDurationBlocks);

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

        delete getAuctionStartTime[borrowHash]; // Mark the auction as completed.
    }

    function liquidate(bytes32 borrowHash) external {
        // Cache the start time of the refinancing auction.
        uint256 start = getAuctionStartTime[borrowHash];

        // Ensure an auction is actually active.
        require(start > 0, "NO_ACTIVE_AUCTION");

        // Get the borrow data associated with the hash.
        BorrowData storage borrowData = getBorrowData[borrowHash];

        // Cache the terms hash associated with the borrow data.
        LoanTerms memory termsData = getLoanTerms[borrowData.termsHash];

        // Calculate the current rate at which the dutch auction would close at.
        uint256 r = calcAuctionRate(uint40(start), termsData.liquidationDurationBlocks);

        // Ensure the rate is above or equal to the liquidation threshold.
        require(r >= LIQ_THRESHOLD, "NOT_INSOLVENT");

        ///////////////////////////////////////////////////////////

        // Send the NFT to the lender.
        termsData.nft.safeTransferFrom(address(this), termsData.lender, borrowData.nftId);

        delete getAuctionStartTime[borrowHash]; // Mark teh auction as completed.
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

    function hashLoanTerms(LoanTerms memory l) internal view returns (bytes32) {
        return keccak256(abi.encode(l));
    }

    function hashBorrowData(BorrowData memory b) internal view returns (bytes32) {
        return keccak256(abi.encode(b));
    }

    /*//////////////////////////////////////////////////////////////
                           CALCULATION HELPERS
    //////////////////////////////////////////////////////////////*/

    function calcInterest(uint40 lastTouchedTime, uint96 lastComputedDebt, uint32 bips)
        internal
        view
        returns (uint256)
    {
        return 0; // TODO: GPT-4
    }

    function calcAuctionRate(uint40 time, uint32 durBlocks) internal view returns (uint256) {
        return 0; // TODO: Dan?
    }
}
