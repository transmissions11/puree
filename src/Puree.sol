// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "solmate/tokens/ERC721.sol";
import "solmate/tokens/WETH.sol";
import "solmate/utils/SafeTransferLib.sol";

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
    // TODO: What is totalAmount for?
    ///////////////////////
    uint16 liquidationDurationBlocks;
    uint32 interestRateBips;
    ///////////////////////
    uint40 deadline;
    uint32 nonce;
}

struct LoanData {
    LoanTerms terms;
    address borrower;
    uint256 nftId;
    uint96 debt;
    uint40 time; // first borrow time
}

// todo: replay and what to do with closed loans

contract Puree {
    using SafeTransferLib for WETH;

    uint256 LIQ_THRESHOLD = 1000000; // todo

    WETH internal weth;

    constructor(WETH _weth) {
        weth = _weth;
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        return ""; // TODO
    }

    mapping(uint256 => LoanTerms) loanData;

    mapping(uint256 => uint256) auctionStartTime;

    mapping(address => uint256) nonce;

    uint256 loanId;

    function bumpNonce(uint256 n) external {
        nonce[msg.sender] += n;
    }

    function borrow(LoanTerms calldata terms, uint256 nftId, uint256 amt) external {
        // TODO: validate signature

        // Take the borrower's collateral NFT and keep it in the Puree contract for safe keeping.
        terms.nft.transferFrom(msg.sender, address(this), nftId);

        // Ensure the amount fits within the lender's terms.
        require(amt <= terms.maxAmount && amt >= terms.minAmount, "INVALID_AMOUNT");

        // TODO: functionize
        require(terms.deadline >= block.timestamp);
        require(terms.nonce <= nonce[terms.lender]);

        // Give the borrower the amount of collateral they've requested.
        weth.safeTransferFrom(terms.lender, msg.sender, amt);

        // Store the loan data.
        loanData[loanId++] = LoanData(terms, msg.sender, nftId, amt, block.timestamp);
    }

    function repay(uint256 id, uint96 amt) external {
        LoanData storage loan = loanData[id];

        weth.safeTransferFrom(msg.sender, loan.lender, amt);

        loan.debt -= amt;

        if (loan.debt < loan.terms.minAmount) {
            loan.nft.transferFrom(address(this), loan.borrower, loan.nftId);

            delete loanData;
        }
    }

    function repayFull(uint256 id) external {
        LoanData storage loan = loanData[id];

        uint256 debt = calcInterest(loan.time, loan.debt);

        weth.safeTransferFrom(msg.sender, loan.terms.lender, debt);

        loan.nft.transferFrom(address(this), loan.borrower, loan.nftId);

        delete loanData;
    }

    function instantRefinance(uint256 id, LoanTerms terms2) external {
        LoanData storage loan = loanData[id];

        require(msg.sender == loan.terms.lender);

        // TODO: functionize
        require(terms2.deadline >= block.timestamp);
        require(terms2.nonce <= nonce[loan.terms.lender]);

        // same
        require(terms2.nft == laon.terms.nft);

        // favorable
        require(terms2.minAmount >= loan.terms.minAmount);
        require(terms2.liquidationDurationBlocks >= loan.terms.liquidationDurationBlocks);
        require(terms2.interestRateBips <= loan.terms.interestRateBips);

        // TODO: buy out the previous lender lol
        // TODO: is it safe to pay them pay arbitrary debt
        uint256 debt = calcInterest(loan.time, loan.debt);
        weth.safeTransferFrom(terms2.lender, loan.terms.lender, debt);

        loan.terms = terms2;
    }

    function kickoffRefinancingAuction(uint256 id) external {
        require(msg.sender == loanData[id].lender);

        require(auctionStartTime[id] == 0);

        auctionStartTime[id] = block.timestamp;
    }

    function auctionRefinance(uint256 id, LoanTerms terms2) external {
        uint256 r = calcAuctionRate;

        LoanData storage loan = loanData[id];

        require(r < LIQ_THRESHOLD);

        require(terms2.deadline >= block.timestamp);

        require(terms2.nonce <= nonce[loan.terms.lender]);

        // same
        require(terms2.nft == loan.terms.nft);

        // favorable
        require(terms2.minAmount >= loan.terms.minAmount);
        require(terms2.liquidationDurationBlocks >= loan.terms.liquidationDurationBlocks);

        require(terms2.interestRateBips <= r);

        // buy out the prev lender
        uint256 debt = calcInterest(loan.time, loan.debt);
        weth.safeTransferFrom(terms2.lender, loan.terms.lender, debt);

        loan.terms = terms2;
    }

    function liquidate(uint256 id) external {
        LoanData storage loan = loanData[id];

        uint256 start = auctionStartTime[id];

        require(start > 0);

        uint256 r = calcAuctionRate(start, loan.liquidationDurationBlocks);

        if (r > LIQ_THRESHOLD) {
            delete auctionStartTime[id];

            loan.nft.transferFrom(address(this), loan.terms.lender, loan.nftId);

            delete loanData[id];
        }
    }
}

function hashLoamTerms(LoanTerms calldata loan) returns (bytes32) {
    return 0x0; // todo
}

function calcInterest(uint40 time, uint32 bips) returns (uint256) {
    return 0; // TODO
}

function calcAuctionRate(uint40 time, uint32 durBlocks) returns (uint256) {
    return 0; // TODO
}
