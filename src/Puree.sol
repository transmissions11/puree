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

    uint256 loanId;

    function borrow(LoanTerms calldata loan, uint256 nftId, uint256 amt) external {
        // Take the borrower's collateral NFT and keep it in the Puree contract for safe keeping.
        loan.nft.transferFrom(msg.sender, address(this), nftId);

        // Ensure the amount fits within the lender's terms.
        require(amt <= loan.maxAmount && amt >= loan.minAmount, "INVALID_AMOUNT");

        // Give the borrower the amount of collateral they've requested.
        weth.safeTransferFrom(loan.lender, msg.sender, amt);

        // Store the loan data.
        loanData[loanId++] = LoanData(loan, msg.sender, nftId, amt, block.timestamp);
    }

    function repay(uint256 id, uint96 amt) external {
        weth.safeTransferFrom(msg.sender, loan.lender, amt);

        if (amt < minAmount) {} // TODO

        loanData[id].debt -= amt; // TODO not handling interest properly
    }

    function repayFull(uint256 id) external {
        uint256 debt = calcInterest(loanData[id].time, loanData[id].debt);

        weth.safeTransferFrom(msg.sender, loan.terms.lender, debt);

        loan.nft.transferFrom(address(this), loan.borrower, loan.nftId);

        delete loanData;
    }

    function repayFull(uint256 id) external {
        uint256 debt = calcInterest(loanData[id].time, loanData[id].debt);

        weth.safeTransferFrom(msg.sender, loan.terms.lender, debt);

        loan.nft.transferFrom(address(this), loan.borrower, loan.nftId);

        delete loanData;
    }
}

function hashLoamTerms(LoanTerms calldata loan) returns (bytes32) {
    return 0x0; // todo
}

function calcInterest(uint40 time, uint32 bips) returns (uint256) {
    return 0; // TODO
}
