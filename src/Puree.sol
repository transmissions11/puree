// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "solmate/tokens/ERC721.sol";
import "solmate/tokens/WETH.sol";
import "solmate/utils/SafeTransferLib.sol";

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

contract Puree {
    using SafeTransferLib for WETH;

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

    function borrow(LoanTerms calldata terms, uint256 nftId, uint256 amt) external {
        // TODO: validate signature

        // Take the borrower's collateral NFT and keep it in the Puree contract for safe keeping.
        loan.nft.transferFrom(msg.sender, address(this), nftId);

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
        weth.safeTransferFrom(msg.sender, loan.lender, amt);

        if (amt < minAmount) {} // TODO

        loanData[id].debt -= amt; // TODO not handling interest properly
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

        // TODO: functionize
        require(terms2.deadline >= block.timestamp);
        require(terms2.nonce <= nonce[terms.lender]);

        // same
        require(terms2.nft == terms1.nft);

        // favorable
        require(terms2.minAmount >= loan.terms.minAmount);
        require(terms2.liquidationDurationBlocks >= loan.terms.liquidationDurationBlocks);
        require(terms2.interestRateBips <= loan.terms.interestRateBips);

        // TODO: buy out the previous lender lol
        // TODO: is it safe to pay them pay arbitrary debt
        uint256 debt = calcInterest(loan.time, loan.debt);
        weth.safeTransferFrom(terms2.lender, loan.terms.lender, debt);

        loan.terms = terms2;

        // TODO: update interest data?
    }

    function kickoffRefinancingAuction(uint256 id) {
        require(msg.sender == loanData[id].lender);

        auctionStartTime[id] = block.timestamp;
    }

    function auctionRefinance(uint256 id, LoanTerms terms2) external {}

    function liquidate(uint256 id) external {}
}

function hashLoamTerms(LoanTerms calldata loan) returns (bytes32) {
    return 0x0; // todo
}

function calcInterest(uint40 time, uint32 bips) returns (uint256) {
    return 0; // TODO
}
