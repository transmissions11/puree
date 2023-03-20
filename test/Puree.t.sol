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
    uint256 constant LENDER2_PK = 0xBABE;

    address immutable LENDER_ADDRESS = vm.addr(LENDER_PK);
    address immutable LENDER2_ADDRESS = vm.addr(LENDER2_PK);

    LoanTerms terms;

    function setUp() public {
        puree = new Puree(weth);

        vm.warp(365 days);

        weth.mint(address(this), 500e18);
        weth.mint(LENDER_ADDRESS, 500e18);
        weth.mint(LENDER2_ADDRESS, 500e18);
        nft.mint(address(this), 1);
        nft.mint(address(this), 2);

        vm.prank(LENDER_ADDRESS);
        weth.approve(address(puree), type(uint256).max);

        vm.prank(LENDER2_ADDRESS);
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

    function submitLenderTerms() internal returns (bytes32) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeTermsDigest(terms));

        return puree.submitTerms(terms, v, r, s);
    }

    function submitLender2Terms() internal returns (bytes32) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER2_PK, puree.computeTermsDigest(terms));

        return puree.submitTerms(terms, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                              SUBMIT TERMS
    //////////////////////////////////////////////////////////////*/

    function testSubmitTerms() public {
        bytes32 termHash = submitLenderTerms();

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
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeTermsDigest(terms));

        terms.nonce = 1;

        vm.expectRevert("INVALID_SIGNATURE");
        puree.submitTerms(terms, v, r, s);
    }

    function testSubmitTerms_expired() public {
        terms.deadline = uint40(block.timestamp - 1 days);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeTermsDigest(terms));

        vm.expectRevert("TERMS_EXPIRED");
        puree.submitTerms(terms, v, r, s);
    }

    function testSubmitTerms_alreadySubmitted() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeTermsDigest(terms));

        puree.submitTerms(terms, v, r, s);

        vm.expectRevert("TERMS_ALREADY_EXISTS");
        puree.submitTerms(terms, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                              BORROW
    //////////////////////////////////////////////////////////////*/

    function testBorrow() public {
        bytes32 termsHash = submitLenderTerms();

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
        bytes32 termsHash = submitLenderTerms();

        termsHash = bytes32(uint256(termsHash) + 1);

        vm.expectRevert("TERMS_EXPIRED_OR_DO_NOT_EXIST");
        puree.newBorrow(termsHash, 1, 10e18);
    }

    function testBorrow_unownedNFT() public {
        bytes32 termsHash = submitLenderTerms();

        vm.expectRevert("WRONG_FROM");
        puree.newBorrow(termsHash, 999, 10e18);
    }

    function testBorrow_overMaxAmount() public {
        bytes32 termsHash = submitLenderTerms();

        vm.expectRevert("INVALID_AMOUNT");
        puree.newBorrow(termsHash, 1, 21e18);
    }

    function testBorrow_underMinAmount() public {
        bytes32 termsHash = submitLenderTerms();

        vm.expectRevert("INVALID_AMOUNT");
        puree.newBorrow(termsHash, 1, 9e18);
    }

    function testBorrow_capacityOverflow() public {
        bytes32 termsHash = submitLenderTerms();

        puree.newBorrow(termsHash, 1, 20e18);
        puree.newBorrow(termsHash, 2, 10e18);

        vm.expectRevert("AT_CAPACITY");
        puree.newBorrow(termsHash, 1, 10e18);
    }

    /*//////////////////////////////////////////////////////////////
                               REPAYMENTS
    //////////////////////////////////////////////////////////////*/

    function testRepayMaxManually() public {
        bytes32 termsHash = submitLenderTerms();

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
        bytes32 termsHash = submitLenderTerms();

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
        bytes32 termsHash = submitLenderTerms();

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
        bytes32 termsHash = submitLenderTerms();

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
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        borrowHash = bytes32(uint256(borrowHash) + 1);

        vm.expectRevert("BORROW_DOES_NOT_EXIST");
        puree.repay(borrowHash, 10e18);
    }

    function testRepay_overAmount() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.expectRevert(stdError.arithmeticError);
        puree.repay(borrowHash, 11e18);
    }

    function testRepay_overAmountAfterTime() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.warp(block.timestamp + 365 days);

        vm.expectRevert(stdError.arithmeticError);
        puree.repay(borrowHash, 50e18);
    }

    /*//////////////////////////////////////////////////////////////
                           INSTANT REFINANCING
    //////////////////////////////////////////////////////////////*/

    function testInstantLenderRefinance() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        terms.interestRateBips = 4000;
        terms.lender = LENDER2_ADDRESS;
        bytes32 newTermsHash = submitLender2Terms();

        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrowHash, newTermsHash);

        assertEq(puree.getTotalAmountConsumed(oldTermsHash), 0);
        assertEq(puree.getTotalAmountConsumed(newTermsHash), 10e18);

        assertEq(weth.balanceOf(LENDER_ADDRESS), 500e18);
        assertEq(weth.balanceOf(LENDER2_ADDRESS), 490e18);
        assertEq(weth.balanceOf(address(this)), 510e18);

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        assertEq(borrowData.borrower, address(this));
        assertEq(borrowData.termsHash, newTermsHash);
        assertEq(borrowData.nftId, 1);
        assertEq(borrowData.lastComputedDebt, 10e18);
        assertEq(borrowData.lastTouchedTime, uint40(block.timestamp));
    }

    function testInstantLenderRefinance_invalidBorrow() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        terms.interestRateBips = 4000;
        terms.lender = LENDER2_ADDRESS;
        bytes32 newTermsHash = submitLender2Terms();

        borrowHash = bytes32(uint256(borrowHash) + 1);

        vm.expectRevert("NOT_LENDER");
        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrowHash, newTermsHash);
    }

    function testInstantLenderRefinance_invalidAmount() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        terms.interestRateBips = 4000;
        terms.lender = LENDER2_ADDRESS;
        terms.minAmount = 999999e18;
        bytes32 newTermsHash = submitLender2Terms();

        vm.expectRevert("INVALID_AMOUNT");
        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrowHash, newTermsHash);
    }

    function testInstantLenderRefinance_invalidTerms() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        terms.interestRateBips = 4000;
        terms.lender = LENDER2_ADDRESS;
        bytes32 newTermsHash = submitLender2Terms();

        newTermsHash = bytes32(uint256(newTermsHash) + 1); // invalidate the terms hash value

        vm.expectRevert("TERMS_EXPIRED_OR_DO_NOT_EXIST");
        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrowHash, newTermsHash);
    }

    function testInstantLenderRefinance_unfavorableTerms() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        terms.interestRateBips = 6000;
        terms.lender = LENDER2_ADDRESS;
        bytes32 newTermsHash = submitLender2Terms();

        vm.expectRevert("TERMS_NOT_FAVORABLE");
        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrowHash, newTermsHash);
    }

    function testInstantLenderRefinance_expiredTerms() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        terms.interestRateBips = 4000;
        terms.lender = LENDER2_ADDRESS;
        terms.deadline = uint40(block.timestamp);
        bytes32 newTermsHash = submitLender2Terms();

        vm.warp(block.timestamp + 1 days);

        vm.expectRevert("TERMS_EXPIRED_OR_DO_NOT_EXIST");
        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrowHash, newTermsHash);
    }

    function testInstantLenderRefinance_capacityOverflow() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        terms.interestRateBips = 4000;
        terms.lender = LENDER2_ADDRESS;
        terms.totalAmount = 5e18;
        bytes32 newTermsHash = submitLender2Terms();

        vm.expectRevert("NEW_TERMS_AT_CAPACITY");
        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrowHash, newTermsHash);
    }

    /*//////////////////////////////////////////////////////////////
                             AUCTION KICKOFF
    //////////////////////////////////////////////////////////////*/

    function testKickoffRefinancingAuction() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        assertEq(puree.getAuctionStartBlock(borrowHash), 0);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);

        assertEq(puree.getAuctionStartBlock(borrowHash), block.number);
    }

    function testKickoffRefinancingAuction_invalidBorrow() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        borrowHash = bytes32(uint256(borrowHash) + 1);

        vm.expectRevert("NOT_LENDER");
        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);
    }

    function testKickoffRefinancingAuction_alreadyActive() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);

        vm.prank(LENDER_ADDRESS);
        vm.expectRevert("AUCTION_ALREADY_STARTED");
        puree.kickoffRefinancingAuction(borrowHash);
    }

    /*//////////////////////////////////////////////////////////////
                     REFINANCING AUCTION SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    function testSettleRefinancingAuction() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);

        vm.roll(block.number + 55);

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

        uint256 newRate = puree.calcRefinancingAuctionRate(
            puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
        );

        assertEq(newRate, 6747);

        terms.interestRateBips = uint32(newRate);
        terms.lender = LENDER2_ADDRESS;
        bytes32 newTermsHash = submitLender2Terms();

        puree.settleRefinancingAuction(borrowHash, newTermsHash);

        assertEq(puree.getAuctionStartBlock(borrowHash), 0);

        assertEq(puree.getBorrow(borrowHash).termsHash, newTermsHash);
        assertEq(puree.getBorrow(borrowHash).lastComputedDebt, 10e18);
        assertEq(puree.getBorrow(borrowHash).lastTouchedTime, uint40(block.timestamp));

        assertEq(puree.getTotalAmountConsumed(oldTermsHash), 0);
        assertEq(puree.getTotalAmountConsumed(newTermsHash), 10e18);

        assertEq(weth.balanceOf(LENDER_ADDRESS), 500e18);
        assertEq(weth.balanceOf(LENDER2_ADDRESS), 490e18);
    }

    function testSettleRefinancingAuctionPricing() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);

        uint256 lastRate = 0;

        for (uint256 i = 0; i < 100; i++) {
            vm.roll(block.number + 1);

            BorrowData memory borrowData = puree.getBorrow(borrowHash);

            LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

            uint256 newRate = puree.calcRefinancingAuctionRate(
                puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
            );

            assertGe(newRate, lastRate);

            if (i == 49) assertEq(newRate, terms.interestRateBips);
            if (newRate == 99) assertEq(newRate, puree.LIQ_THRESHOLD());

            lastRate = newRate;
        }
    }

    function testSettleRefinancingAuction_invalidBorrow() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);

        vm.roll(block.number + 55);

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

        uint256 newRate = puree.calcRefinancingAuctionRate(
            puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
        );

        assertEq(newRate, 6747);

        terms.interestRateBips = uint32(newRate);
        terms.lender = LENDER2_ADDRESS;
        bytes32 newTermsHash = submitLender2Terms();

        borrowHash = bytes32(uint256(borrowHash) + 1);

        vm.expectRevert("NO_ACTIVE_AUCTION");
        puree.settleRefinancingAuction(borrowHash, newTermsHash);
    }

    function testSettleRefinancingAuction_unfairTerms() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);

        vm.roll(block.number + 55);

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

        uint256 newRate = puree.calcRefinancingAuctionRate(
            puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
        );

        assertEq(newRate, 6747);

        terms.interestRateBips = uint32(newRate * 2);
        terms.lender = LENDER2_ADDRESS;
        bytes32 newTermsHash = submitLender2Terms();

        vm.expectRevert("TERMS_NOT_REASONABLE");
        puree.settleRefinancingAuction(borrowHash, newTermsHash);
    }

    function testSettleRefinancingAuction_capacityOverflow() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);

        vm.roll(block.number + 55);

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

        uint256 newRate = puree.calcRefinancingAuctionRate(
            puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
        );

        assertEq(newRate, 6747);

        terms.interestRateBips = uint32(newRate);
        terms.lender = LENDER2_ADDRESS;
        terms.totalAmount = 5e18;
        bytes32 newTermsHash = submitLender2Terms();

        vm.expectRevert("NEW_TERMS_AT_CAPACITY");
        puree.settleRefinancingAuction(borrowHash, newTermsHash);
    }

    function testSettleRefinancingAuction_termsExpired() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);

        vm.roll(block.number + 55);

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

        uint256 newRate = puree.calcRefinancingAuctionRate(
            puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
        );

        assertEq(newRate, 6747);

        terms.interestRateBips = uint32(newRate);
        terms.lender = LENDER2_ADDRESS;
        bytes32 newTermsHash = submitLender2Terms();

        vm.warp(terms.deadline + 1 days);

        vm.expectRevert("TERMS_EXPIRED_OR_DO_NOT_EXIST");
        puree.settleRefinancingAuction(borrowHash, newTermsHash);
    }

    function testSettleRefinancingAuction_invalidAmount() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);

        vm.roll(block.number + 55);

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

        uint256 newRate = puree.calcRefinancingAuctionRate(
            puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
        );

        assertEq(newRate, 6747);

        terms.interestRateBips = uint32(newRate);
        terms.maxAmount = 5e18;
        terms.lender = LENDER2_ADDRESS;
        bytes32 newTermsHash = submitLender2Terms();

        vm.expectRevert("INVALID_AMOUNT");
        puree.settleRefinancingAuction(borrowHash, newTermsHash);
    }

    function testSettleRefinancingAuction_insolvent() public {
        bytes32 oldTermsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);

        vm.roll(block.number + 100);

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

        uint256 newRate = puree.calcRefinancingAuctionRate(
            puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
        );

        assertEq(newRate, puree.LIQ_THRESHOLD());

        terms.interestRateBips = uint32(newRate);
        terms.lender = LENDER2_ADDRESS;
        bytes32 newTermsHash = submitLender2Terms();

        vm.expectRevert("INSOLVENT");
        puree.settleRefinancingAuction(borrowHash, newTermsHash);
    }

    /*//////////////////////////////////////////////////////////////
                               LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    function testLiquidate() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);

        vm.roll(block.number + 100);

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

        uint256 newRate = puree.calcRefinancingAuctionRate(
            puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
        );

        assertEq(newRate, puree.LIQ_THRESHOLD());

        puree.liquidate(borrowHash);

        assertEq(puree.getAuctionStartBlock(borrowHash), 0);

        assertEq(nft.ownerOf(borrowData.nftId), LENDER_ADDRESS);
    }

    function testLiquidate_noActiveAuction() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.expectRevert("NO_ACTIVE_AUCTION");
        puree.liquidate(borrowHash);
    }

    function testLiquidate_notInsolvent() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrowHash);

        vm.roll(block.number + 55);

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

        uint256 newRate = puree.calcRefinancingAuctionRate(
            puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
        );

        assertEq(newRate, 6747);

        vm.expectRevert("NOT_INSOLVENT");
        puree.liquidate(borrowHash);
    }

    /*//////////////////////////////////////////////////////////////
                             FURTHER BORROW
    //////////////////////////////////////////////////////////////*/

    function testFurtherBorrow() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        puree.furtherBorrow(borrowHash, 1e18);

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        assertEq(borrowData.lastComputedDebt, 11e18);
    }

    function testFurtherBorrow_notBorrower() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.prank(address(0xBEEFBABE));
        vm.expectRevert("NOT_BORROWER");
        puree.furtherBorrow(borrowHash, 1e18);
    }

    function testFurtherBorrow_termsExpired() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.warp(terms.deadline + 1 days);

        vm.expectRevert("TERMS_EXPIRED_OR_DO_NOT_EXIST");
        puree.furtherBorrow(borrowHash, 1e18);
    }

    function testFurtherBorrow_termsDoNotExist() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        borrowHash = bytes32(uint256(borrowHash) + 1);

        vm.expectRevert("NOT_BORROWER");
        puree.furtherBorrow(borrowHash, 1e18);
    }

    function testFurtherBorrow_invalidAmount() public {
        bytes32 termsHash = submitLenderTerms();

        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.expectRevert("INVALID_AMOUNT");
        puree.furtherBorrow(borrowHash, 11e18);
    }

    function testFurtherBorrow_atCapacity() public {
        bytes32 termsHash = submitLenderTerms();

        puree.newBorrow(termsHash, 2, 20e18);
        bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

        vm.expectRevert("AT_CAPACITY");
        puree.furtherBorrow(borrowHash, 1e18);
    }

    /*//////////////////////////////////////////////////////////////
                            NONCE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function testBumpNonce() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeTermsDigest(terms));

        assertEq(puree.getNonce(LENDER_ADDRESS), 0);

        vm.prank(LENDER_ADDRESS);
        puree.bumpNonce(1);

        assertEq(puree.getNonce(LENDER_ADDRESS), 1);

        vm.expectRevert("TERMS_EXPIRED");
        puree.submitTerms(terms, v, r, s);
    }

    /*//////////////////////////////////////////////////////////////
                         SUBMIT TERMS AND BORROW
    //////////////////////////////////////////////////////////////*/

    function testSubmitTermsAndBorrow() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeTermsDigest(terms));

        bytes32 borrowHash = puree.submitTermsAndBorrow(terms, v, r, s, 1, 10e18);

        assertEq(weth.balanceOf(address(this)), 510e18);
        assertEq(weth.balanceOf(LENDER_ADDRESS), 490e18);
        assertEq(nft.ownerOf(1), address(puree));

        BorrowData memory borrowData = puree.getBorrow(borrowHash);

        assertEq(borrowData.borrower, address(this));
        assertEq(borrowData.termsHash, borrowData.termsHash);
        assertEq(borrowData.nftId, 1);
        assertEq(borrowData.lastComputedDebt, 10e18);
        assertEq(borrowData.lastTouchedTime, uint40(block.timestamp));

        assertEq(puree.getTotalAmountConsumed(borrowData.termsHash), 10e18);
    }
}
