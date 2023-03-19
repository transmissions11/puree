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

    LoanTerms terms;

    function setUp() public {
        puree = new Puree(weth);

        vm.warp(365 days);

        weth.mint(address(this), 500e18);
        weth.mint(LENDER_ADDRESS, 500e18);
        nft.mint(address(this), 1);
        nft.mint(address(this), 2);

        vm.prank(LENDER_ADDRESS);
        weth.approve(address(puree), type(uint256).max);

        nft.setApprovalForAll(address(puree), true);
        weth.approve(address(puree), type(uint256).max);

        terms = LoanTerms({
            lender: LENDER_ADDRESS,
            nft: nft,
            minAmount: 10e18,
            maxAmount: 20e18,
            totalAmount: 30e18,
            deadline: uint40(block.timestamp + 1 days),
            nonce: 0,
            liquidationDurationBlocks: 100,
            interestRateBips: 5000 // 50% IRM
        });
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function submitTerms() internal returns (bytes32) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.getTermsDigest(terms));

        return puree.submitTerms(terms, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                              SUBMIT TERMS
    //////////////////////////////////////////////////////////////*/

    function testSubmitTerms() public {
        bytes32 termHash = submitTerms();

        assertEq(termHash, puree.hashLoanTerms(terms));

        LoanTerms memory savedTerms = puree.getTerms(termHash);

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

    function testSubmitTerms_invalidSignature() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.getTermsDigest(terms));

        terms.nonce = 1;

        vm.expectRevert("INVALID_SIGNATURE");
        puree.submitTerms(terms, v, r, s);
    }

    function testSubmitTerms_expired() public {
        terms.deadline = uint40(block.timestamp - 1 days);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.getTermsDigest(terms));

        vm.expectRevert("TERMS_EXPIRED");
        puree.submitTerms(terms, v, r, s);
    }

    function testSubmitTerms_alreadySubmitted() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.getTermsDigest(terms));

        puree.submitTerms(terms, v, r, s);

        vm.expectRevert("TERMS_ALREADY_EXISTS");
        puree.submitTerms(terms, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                              BORROW
    //////////////////////////////////////////////////////////////*/

    function testBorrow() public {
        bytes32 termsHash = submitTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        assertEq(weth.balanceOf(address(this)), 510e18);
        assertEq(weth.balanceOf(LENDER_ADDRESS), 490e18);
        assertEq(nft.ownerOf(1), address(puree));

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        assertEq(borrowData.borrower, address(this));
        assertEq(borrowData.termsHash, termsHash);
        assertEq(borrowData.nftId, 1);
        assertEq(borrowData.lastComputedDebt, 10e18);
        assertEq(borrowData.lastTouchedTime, uint40(block.timestamp));

        assertEq(puree.getTotalAmountConsumed(termsHash), 10e18);
    }

    function testBorrow_invalidTerms() public {
        bytes32 termsHash = submitTerms();

        termsHash = bytes32(uint256(termsHash) + 1);

        vm.expectRevert("TERMS_EXPIRED_OR_DO_NOT_EXIST");
        puree.newBorrow(termsHash, 1, 10e18);
    }

    function testBorrow_unownedNFT() public {
        bytes32 termsHash = submitTerms();

        vm.expectRevert("WRONG_FROM");
        puree.newBorrow(termsHash, 999, 10e18);
    }

    function testBorrow_overMaxAmount() public {
        bytes32 termsHash = submitTerms();

        vm.expectRevert("INVALID_AMOUNT");
        puree.newBorrow(termsHash, 1, 21e18);
    }

    function testBorrow_underMinAmount() public {
        bytes32 termsHash = submitTerms();

        vm.expectRevert("INVALID_AMOUNT");
        puree.newBorrow(termsHash, 1, 9e18);
    }

    function testBorrow_overTotalAmount() public {
        bytes32 termsHash = submitTerms();

        puree.newBorrow(termsHash, 1, 20e18);
        puree.newBorrow(termsHash, 2, 10e18);

        vm.expectRevert("AT_CAPACITY");
        puree.newBorrow(termsHash, 1, 10e18);
    }

    /*//////////////////////////////////////////////////////////////
                               REPAYMENTS
    //////////////////////////////////////////////////////////////*/

    function testRepayMaxManually() public {
        bytes32 termsHash = submitTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        puree.repay(borrowHash, 10e18);

        assertEq(weth.balanceOf(address(this)), 500e18);
        assertEq(weth.balanceOf(LENDER_ADDRESS), 500e18);
        assertEq(nft.ownerOf(1), address(this));

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        assertEq(borrowData.borrower, address(this));
        assertEq(borrowData.termsHash, termsHash);
        assertEq(borrowData.nftId, 1);
        assertEq(borrowData.lastComputedDebt, 0);
        assertEq(borrowData.lastTouchedTime, uint40(block.timestamp));

        assertEq(puree.getTotalAmountConsumed(termsHash), 0);
    }

    function testRepayPartial() public {
        bytes32 termsHash = submitTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        puree.repay(borrowHash, 5e18);

        assertEq(weth.balanceOf(address(this)), 505e18);
        assertEq(weth.balanceOf(LENDER_ADDRESS), 495e18);
        assertEq(nft.ownerOf(1), address(puree));

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        assertEq(borrowData.borrower, address(this));
        assertEq(borrowData.termsHash, termsHash);
        assertEq(borrowData.nftId, 1);
        assertEq(borrowData.lastComputedDebt, 5e18);
        assertEq(borrowData.lastTouchedTime, uint40(block.timestamp));

        assertEq(puree.getTotalAmountConsumed(termsHash), 5e18);
    }

    function testRepayMaxAutomatically() public {
        bytes32 termsHash = submitTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        puree.repay(borrowHash, type(uint96).max);

        assertEq(weth.balanceOf(address(this)), 500e18);
        assertEq(weth.balanceOf(LENDER_ADDRESS), 500e18);
        assertEq(nft.ownerOf(1), address(this));

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        assertEq(borrowData.borrower, address(this));
        assertEq(borrowData.termsHash, termsHash);
        assertEq(borrowData.nftId, 1);
        assertEq(borrowData.lastComputedDebt, 0);
        assertEq(borrowData.lastTouchedTime, uint40(block.timestamp));

        assertEq(puree.getTotalAmountConsumed(termsHash), 0);
    }

    function testRepayMaxAfterTime() public {
        bytes32 termsHash = submitTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.warp(block.timestamp + 365 days);

        puree.repay(borrowHash, type(uint96).max);

        assertEq(weth.balanceOf(address(this)), 493.51278729299871854e18);
        assertEq(weth.balanceOf(LENDER_ADDRESS), 506.48721270700128146e18);
        assertEq(nft.ownerOf(1), address(this));

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        assertEq(borrowData.borrower, address(this));
        assertEq(borrowData.termsHash, termsHash);
        assertEq(borrowData.nftId, 1);
        assertEq(borrowData.lastComputedDebt, 0);
        assertEq(borrowData.lastTouchedTime, uint40(block.timestamp));

        assertEq(puree.getTotalAmountConsumed(termsHash), 0);
    }

    function testRepay_invalidBorrow() public {
        bytes32 termsHash = submitTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        borrowHash = bytes32(uint256(borrowHash) + 1);

        vm.expectRevert("BORROW_DOES_NOT_EXIST");
        puree.repay(borrowHash, 10e18);
    }

    function testRepay_overAmount() public {
        bytes32 termsHash = submitTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.expectRevert(stdError.arithmeticError);
        puree.repay(borrowHash, 11e18);
    }

    function testRepay_overAmountAfterTime() public {
        bytes32 termsHash = submitTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.warp(block.timestamp + 365 days);

        vm.expectRevert(stdError.arithmeticError);
        puree.repay(borrowHash, 50e18);
    }
}
