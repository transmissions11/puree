// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "forge-std/Test.sol";

import "solmate/test/utils/mocks/MockERC20.sol";
import "solmate/test/utils/mocks/MockERC721.sol";

import "src/Puree.sol";

contract PureeTest is Test {
    MockERC20 public weth = new MockERC20("WETH", "WETH", 18);
    MockERC721 public nft = new MockERC721("Bored Apes", "BAPES");

    Puree public puree;

    uint256 constant LENDER_PK = 0xBEEF;

    address immutable LENDER_ADDRESS = vm.addr(LENDER_PK);

    function setUp() public {
        puree = new Puree(weth);

        weth.mint(address(this), 500e18);
        weth.mint(LENDER_ADDRESS, 500e18);
        nft.mint(address(this), 1);
    }

    function testSubmitTerms() public {
        LoanTerms memory terms = LoanTerms({
            lender: LENDER_ADDRESS,
            nft: nft,
            minAmount: 10e18,
            maxAmount: 20e18,
            totalAmount: 100e18,
            deadline: uint40(block.timestamp + 1 days),
            nonce: 0,
            liquidationDurationBlocks: 100,
            interestRateBips: 100
        });

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.getTermsDigest(terms));

        puree.submitTerms(terms, v, r, s);

        LoanTerms memory savedTerms = puree.getTerms(puree.hashLoanTerms(terms));

        assertEq(savedTerms.lender, terms.lender);
        assertEq(address(savedTerms.nft), address(terms.nft));
        assertEq(savedTerms.minAmount, terms.minAmount);
        assertEq(savedTerms.maxAmount, terms.maxAmount);
        assertEq(savedTerms.totalAmount, terms.totalAmount);
        assertEq(savedTerms.deadline, terms.deadline);
        assertEq(savedTerms.nonce, terms.nonce);
        assertEq(savedTerms.liquidationDurationBlocks, terms.liquidationDurationBlocks);
        assertEq(savedTerms.interestRateBips, terms.interestRateBips);
    }
}
