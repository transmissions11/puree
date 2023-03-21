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

    Offer offer;

    function setUp() public {
        puree = new Puree(weth);

        vm.warp(365 days);

        weth.mint(address(this), 500e18);
        weth.mint(LENDER_ADDRESS, 500e18);
        weth.mint(LENDER2_ADDRESS, 500e18);
        nft.mint(address(this), 1);
        nft.mint(address(this), 2);
        nft.mint(address(this), 3);
        // For more accurate benchmarking, because large
        // collections will already be in the contract.
        nft.mint(address(puree), 0);

        vm.prank(LENDER_ADDRESS);
        weth.approve(address(puree), type(uint256).max);

        vm.prank(LENDER2_ADDRESS);
        weth.approve(address(puree), type(uint256).max);

        nft.setApprovalForAll(address(puree), true);
        weth.approve(address(puree), type(uint256).max);

        offer = Offer({
            nonce: 0,
            deadline: uint40(block.timestamp + 1 days),
            terms: Terms({
                lender: LENDER_ADDRESS,
                nft: nft,
                minAmount: 10e18,
                maxAmount: 20e18,
                totalAmount: 30e18,
                liquidationDurationBlocks: 100,
                interestRateBips: 5000 // 50% IRM
            })
        });
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function newBorrow() internal returns (Borrow memory borrow, uint256 borrowId) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeOfferDigest(offer));

        borrowId = puree.newBorrow(offer, v, r, s, 1, 10e18);

        borrow = Borrow({
            terms: offer.terms,
            borrower: address(this),
            nftId: 1,
            lastComputedDebt: 10e18,
            lastTouchedTime: uint40(block.timestamp),
            auctionStartBlock: 0
        });
    }

    /*//////////////////////////////////////////////////////////////
                              BORROW
    //////////////////////////////////////////////////////////////*/

    function testBorrow() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        assertEq(borrowId, 1);
        assertEq(puree.nextBorrowId(), 2);
        assertEq(weth.balanceOf(address(this)), 510e18);
        assertEq(weth.balanceOf(LENDER_ADDRESS), 490e18);
        assertEq(nft.ownerOf(1), address(puree));

        bytes32 borrowHash = puree.getBorrowHash(borrowId);

        assertEq(borrowHash, keccak256(abi.encode(borrow)));

        assertEq(puree.getTotalAmountOfTermsConsumed(keccak256(abi.encode(offer.terms))), 10e18);
    }

    function testBorrow_invalidSignature() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeOfferDigest(offer));

        offer.terms.maxAmount = 999999e18;

        vm.expectRevert("INVALID_OFFER_SIGNATURE");
        puree.newBorrow(offer, v, r, s, 1, 10e18);
    }

    function testBorrow_expiredOffer() public {
        offer.deadline = uint40(block.timestamp - 1 days);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeOfferDigest(offer));

        vm.expectRevert("OFFER_EXPIRED");
        puree.newBorrow(offer, v, r, s, 1, 10e18);
    }

    function testBorrow_unownedNFT() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeOfferDigest(offer));

        vm.expectRevert("WRONG_FROM");
        puree.newBorrow(offer, v, r, s, 999, 10e18);
    }

    function testBorrow_overMaxAmount() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeOfferDigest(offer));

        vm.expectRevert("INVALID_AMOUNT");
        puree.newBorrow(offer, v, r, s, 1, 21e18);
    }

    function testBorrow_underMinAmount() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeOfferDigest(offer));

        vm.expectRevert("INVALID_AMOUNT");
        puree.newBorrow(offer, v, r, s, 1, 9e19);
    }

    function testBorrow_capacityOverflow() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeOfferDigest(offer));

        puree.newBorrow(offer, v, r, s, 1, 20e18);
        puree.newBorrow(offer, v, r, s, 2, 10e18);

        vm.expectRevert("AT_CAPACITY");
        puree.newBorrow(offer, v, r, s, 3, 10e18);
    }

    /*//////////////////////////////////////////////////////////////
                             FURTHER BORROW
    //////////////////////////////////////////////////////////////*/

    function testFurtherBorrow() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        puree.furtherBorrow(borrow, borrowId, 1e18);

        bytes32 borrowHash = puree.getBorrowHash(borrowId);

        assertEq(
            borrowHash,
            keccak256(
                abi.encode(
                    Borrow({
                        terms: borrow.terms,
                        borrower: borrow.borrower,
                        nftId: borrow.nftId,
                        lastComputedDebt: 11e18,
                        lastTouchedTime: uint40(block.timestamp),
                        auctionStartBlock: borrow.auctionStartBlock
                    })
                )
            )
        );
    }

    function testFurtherBorrow_notBorrower() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        vm.prank(address(0xBEEFFEED));
        vm.expectRevert("NOT_BORROWER");
        puree.furtherBorrow(borrow, borrowId, 1e18);
    }

    function testFurtherBorrow_invalidBorrowPreimage() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        borrow.nftId = 999;

        vm.expectRevert("INVALID_BORROW_PREIMAGE");
        puree.furtherBorrow(borrow, borrowId, 1e18);
    }

    function testFurtherBorrow_invalidAmount() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        vm.expectRevert("INVALID_AMOUNT");
        puree.furtherBorrow(borrow, borrowId, 21e18);
    }

    function testFurtherBorrow_capacityOverflow() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeOfferDigest(offer));

        puree.newBorrow(offer, v, r, s, 1, 20e18);
        uint256 borrowId = puree.newBorrow(offer, v, r, s, 2, 10e18);

        Borrow memory borrow = Borrow({
            terms: offer.terms,
            borrower: address(this),
            nftId: 2,
            lastComputedDebt: 10e18,
            lastTouchedTime: uint40(block.timestamp),
            auctionStartBlock: 0
        });

        vm.expectRevert("AT_CAPACITY");
        puree.furtherBorrow(borrow, borrowId, 10e18);
    }

    /*//////////////////////////////////////////////////////////////
                               REPAYMENTS
    //////////////////////////////////////////////////////////////*/

    function testRepayMaxManually() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        puree.repay(borrow, borrowId, 10e18);

        assertEq(weth.balanceOf(address(this)), 500e18);
        assertEq(weth.balanceOf(LENDER_ADDRESS), 500e18);
        assertEq(nft.ownerOf(1), address(this));

        bytes32 borrowHash = puree.getBorrowHash(borrowId);

        assertEq(
            borrowHash,
            keccak256(
                abi.encode(
                    Borrow({
                        terms: borrow.terms,
                        borrower: borrow.borrower,
                        nftId: borrow.nftId,
                        lastComputedDebt: 0,
                        lastTouchedTime: uint40(block.timestamp),
                        auctionStartBlock: borrow.auctionStartBlock
                    })
                )
            )
        );

        assertEq(puree.getTotalAmountOfTermsConsumed(keccak256(abi.encode(offer.terms))), 0);
    }

    function testRepayPartial() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        puree.repay(borrow, borrowId, 5e18);

        assertEq(weth.balanceOf(address(this)), 505e18);
        assertEq(weth.balanceOf(LENDER_ADDRESS), 495e18);
        assertEq(nft.ownerOf(1), address(puree));

        bytes32 borrowHash = puree.getBorrowHash(borrowId);

        assertEq(
            borrowHash,
            keccak256(
                abi.encode(
                    Borrow({
                        terms: borrow.terms,
                        borrower: borrow.borrower,
                        nftId: borrow.nftId,
                        lastComputedDebt: 5e18,
                        lastTouchedTime: uint40(block.timestamp),
                        auctionStartBlock: borrow.auctionStartBlock
                    })
                )
            )
        );

        assertEq(puree.getTotalAmountOfTermsConsumed(keccak256(abi.encode(offer.terms))), 5e18);
    }

    function testRepayMaxAutomatically() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        puree.repay(borrow, borrowId, type(uint96).max);

        assertEq(weth.balanceOf(address(this)), 500e18);
        assertEq(weth.balanceOf(LENDER_ADDRESS), 500e18);
        assertEq(nft.ownerOf(1), address(this));

        bytes32 borrowHash = puree.getBorrowHash(borrowId);

        assertEq(
            borrowHash,
            keccak256(
                abi.encode(
                    Borrow({
                        terms: borrow.terms,
                        borrower: borrow.borrower,
                        nftId: borrow.nftId,
                        lastComputedDebt: 0,
                        lastTouchedTime: uint40(block.timestamp),
                        auctionStartBlock: borrow.auctionStartBlock
                    })
                )
            )
        );

        assertEq(puree.getTotalAmountOfTermsConsumed(keccak256(abi.encode(offer.terms))), 0);
    }

    function testRepayMaxAfterTime() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        vm.warp(block.timestamp + 365 days);

        puree.repay(borrow, borrowId, type(uint96).max);

        assertEq(weth.balanceOf(address(this)), 493.51278729299871854e18);
        assertEq(weth.balanceOf(LENDER_ADDRESS), 506.48721270700128146e18);
        assertEq(nft.ownerOf(1), address(this));

        bytes32 borrowHash = puree.getBorrowHash(borrowId);

        assertEq(
            borrowHash,
            keccak256(
                abi.encode(
                    Borrow({
                        terms: borrow.terms,
                        borrower: borrow.borrower,
                        nftId: borrow.nftId,
                        lastComputedDebt: 0,
                        lastTouchedTime: uint40(block.timestamp),
                        auctionStartBlock: borrow.auctionStartBlock
                    })
                )
            )
        );

        assertEq(puree.getTotalAmountOfTermsConsumed(keccak256(abi.encode(offer.terms))), 0);
    }

    function testRepay_invalidBorrowPreimage() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        borrow.nftId = 999;

        vm.expectRevert("INVALID_BORROW_PREIMAGE");
        puree.repay(borrow, borrowId, 10e18);
    }

    function testRepay_overAmount() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        vm.expectRevert(stdError.arithmeticError);
        puree.repay(borrow, borrowId, 50e18);
    }

    function testRepay_overAmountAfterTime() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        vm.warp(block.timestamp + 365 days);

        vm.expectRevert(stdError.arithmeticError);
        puree.repay(borrow, borrowId, 50e18);
    }

    /*//////////////////////////////////////////////////////////////
                           INSTANT REFINANCING
    //////////////////////////////////////////////////////////////*/

    function testInstantLenderRefinance() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        offer.terms.interestRateBips = 4000;
        offer.terms.lender = LENDER2_ADDRESS;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER2_PK, puree.computeOfferDigest(offer));

        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrow, borrowId, offer, v, r, s);

        assertEq(puree.getTotalAmountOfTermsConsumed(keccak256(abi.encode(borrow.terms))), 0);
        assertEq(puree.getTotalAmountOfTermsConsumed(keccak256(abi.encode(offer.terms))), 10e18);

        assertEq(weth.balanceOf(LENDER_ADDRESS), 500e18);
        assertEq(weth.balanceOf(LENDER2_ADDRESS), 490e18);
        assertEq(weth.balanceOf(address(this)), 510e18);

        bytes32 borrowHash = puree.getBorrowHash(borrowId);

        assertEq(
            borrowHash,
            keccak256(
                abi.encode(
                    Borrow({
                        terms: offer.terms,
                        borrower: borrow.borrower,
                        nftId: borrow.nftId,
                        lastComputedDebt: uint96(10e18),
                        lastTouchedTime: uint40(block.timestamp),
                        auctionStartBlock: borrow.auctionStartBlock
                    })
                )
            )
        );
    }

    function testInstantLenderRefinanceAfterTime() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        vm.warp(block.timestamp + 365 days);

        offer.terms.interestRateBips = 4000;
        offer.terms.lender = LENDER2_ADDRESS;
        offer.deadline = uint40(block.timestamp + 1 days);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER2_PK, puree.computeOfferDigest(offer));

        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrow, borrowId, offer, v, r, s);

        assertEq(puree.getTotalAmountOfTermsConsumed(keccak256(abi.encode(borrow.terms))), 0);
        assertEq(puree.getTotalAmountOfTermsConsumed(keccak256(abi.encode(offer.terms))), 16.48721270700128146e18);

        assertEq(weth.balanceOf(LENDER_ADDRESS), 506.48721270700128146e18);
        assertEq(weth.balanceOf(LENDER2_ADDRESS), 483.51278729299871854e18);
        assertEq(weth.balanceOf(address(this)), 510e18);

        bytes32 borrowHash = puree.getBorrowHash(borrowId);

        assertEq(
            borrowHash,
            keccak256(
                abi.encode(
                    Borrow({
                        terms: offer.terms,
                        borrower: borrow.borrower,
                        nftId: borrow.nftId,
                        lastComputedDebt: uint96(16.48721270700128146e18),
                        lastTouchedTime: uint40(block.timestamp),
                        auctionStartBlock: borrow.auctionStartBlock
                    })
                )
            )
        );
    }

    function testInstantLenderRefinance_invalidBorrow() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        offer.terms.interestRateBips = 4000;
        offer.terms.lender = LENDER2_ADDRESS;

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER2_PK, puree.computeOfferDigest(offer));

        vm.expectRevert("INVALID_BORROW_PREIMAGE");
        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrow, borrowId + 1, offer, v, r, s);
    }

    function testInstantLenderRefinance_invalidAmount() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        vm.warp(block.timestamp + (365 days) * 10);

        assertEq(
            puree.computeCurrentDebt(borrow.lastTouchedTime, borrow.lastComputedDebt, borrow.terms.interestRateBips),
            1484.13159102576603421e18
        );

        offer.terms.interestRateBips = 4000;
        offer.terms.lender = LENDER2_ADDRESS;
        offer.deadline = uint40(block.timestamp + 1 days);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER2_PK, puree.computeOfferDigest(offer));

        vm.expectRevert("iNVALID_DEBT_AMOUNT");
        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrow, borrowId, offer, v, r, s);
    }

    function testInstantLenderRefinance_notLender() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        offer.terms.interestRateBips = 4000;
        offer.terms.lender = LENDER2_ADDRESS;
        offer.deadline = uint40(block.timestamp + 1 days);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER2_PK, puree.computeOfferDigest(offer));

        vm.expectRevert("NOT_LENDER");
        puree.instantLenderRefinance(borrow, borrowId, offer, v, r, s);
    }

    function testInstantLenderRefinance_unfavorableTerms() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        offer.terms.minAmount = 9999999999e18;
        offer.terms.lender = LENDER2_ADDRESS;
        offer.deadline = uint40(block.timestamp + 1 days);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER2_PK, puree.computeOfferDigest(offer));

        vm.expectRevert("TERMS_NOT_FAVORABLE");
        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrow, borrowId, offer, v, r, s);
    }

    function testInstantLenderRefinance_expiredOffer() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        offer.terms.interestRateBips = 4000;
        offer.terms.lender = LENDER2_ADDRESS;
        offer.deadline = uint40(block.timestamp - 1 days);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER2_PK, puree.computeOfferDigest(offer));

        vm.expectRevert("OFFER_EXPIRED");
        vm.prank(LENDER_ADDRESS);
        puree.instantLenderRefinance(borrow, borrowId, offer, v, r, s);
    }

    function testInstantLenderRefinance_capacityOverflow() public {
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(LENDER_PK, puree.computeOfferDigest(offer));

        Offer memory oldOffer = offer;

        puree.newBorrow(offer, v1, r1, s1, 1, 10e18);
        puree.newBorrow(offer, v1, r1, s1, 2, 20e18);

        offer.terms.interestRateBips = 6000;
        offer.terms.lender = LENDER2_ADDRESS;
        offer.deadline = uint40(block.timestamp + 1 days);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER2_PK, puree.computeOfferDigest(offer));

        uint256 borrowId = puree.newBorrow(offer, v, r, s, 3, 10e18);

        Borrow memory borrow = Borrow({
            terms: offer.terms,
            borrower: address(this),
            nftId: 3,
            lastComputedDebt: 10e18,
            lastTouchedTime: uint40(block.timestamp),
            auctionStartBlock: 0
        });

        vm.prank(LENDER2_ADDRESS);
        vm.expectRevert("AT_CAPACITY");
        puree.instantLenderRefinance(borrow, borrowId, oldOffer, v1, r1, s1);
    }

    /*//////////////////////////////////////////////////////////////
                             AUCTION KICKOFF
    //////////////////////////////////////////////////////////////*/

    function testKickoffRefinancingAuction() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        assertEq(puree.getBorrowHash(borrowId), keccak256(abi.encode(borrow)));

        assertEq(borrow.auctionStartBlock, 0);

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrow, borrowId);

        assertEq(
            puree.getBorrowHash(borrowId),
            keccak256(
                abi.encode(
                    Borrow({
                        terms: borrow.terms,
                        borrower: borrow.borrower,
                        nftId: borrow.nftId,
                        lastComputedDebt: borrow.lastComputedDebt,
                        lastTouchedTime: borrow.lastTouchedTime,
                        auctionStartBlock: uint40(block.number)
                    })
                )
            )
        );
    }

    function testKickoffRefinancingAuction_notLender() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        vm.expectRevert("NOT_LENDER");
        puree.kickoffRefinancingAuction(borrow, borrowId);
    }

    function testKickoffRefinancingAuction_alreadyActive() public {
        (Borrow memory borrow, uint256 borrowId) = newBorrow();

        vm.prank(LENDER_ADDRESS);
        puree.kickoffRefinancingAuction(borrow, borrowId);

        assertEq(
            puree.getBorrowHash(borrowId),
            keccak256(
                abi.encode(
                    Borrow({
                        terms: borrow.terms,
                        borrower: borrow.borrower,
                        nftId: borrow.nftId,
                        lastComputedDebt: borrow.lastComputedDebt,
                        lastTouchedTime: borrow.lastTouchedTime,
                        auctionStartBlock: uint40(block.number)
                    })
                )
            )
        );

        borrow.auctionStartBlock = uint40(block.number);

        vm.prank(LENDER_ADDRESS);
        vm.expectRevert("AUCTION_ALREADY_STARTED");
        puree.kickoffRefinancingAuction(borrow, borrowId);
    }

    /*//////////////////////////////////////////////////////////////
                     REFINANCING AUCTION SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    // function testSettleRefinancingAuction() public {
    //     bytes32 oldTermsHash = submitLenderTerms();

    //     bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

    //     vm.prank(LENDER_ADDRESS);
    //     puree.kickoffRefinancingAuction(borrowHash);

    //     vm.roll(block.number + 55);

    //     BorrowData memory borrowData = puree.getBorrow(borrowHash);

    //     LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

    //     uint256 newRate = puree.calcRefinancingAuctionRate(
    //         puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
    //     );

    //     assertEq(newRate, 6747);

    //     terms.interestRateBips = uint32(newRate);
    //     terms.lender = LENDER2_ADDRESS;
    //     bytes32 newTermsHash = submitLender2Terms();

    //     puree.settleRefinancingAuction(borrowHash, newTermsHash);

    //     assertEq(puree.getAuctionStartBlock(borrowHash), 0);

    //     assertEq(puree.getBorrow(borrowHash).termsHash, newTermsHash);
    //     assertEq(puree.getBorrow(borrowHash).lastComputedDebt, 10e18);
    //     assertEq(puree.getBorrow(borrowHash).lastTouchedTime, uint40(block.timestamp));

    //     assertEq(puree.getTotalAmountConsumed(oldTermsHash), 0);
    //     assertEq(puree.getTotalAmountConsumed(newTermsHash), 10e18);

    //     assertEq(weth.balanceOf(LENDER_ADDRESS), 500e18);
    //     assertEq(weth.balanceOf(LENDER2_ADDRESS), 490e18);
    // }

    // function testSettleRefinancingAuctionPricing() public {
    //     bytes32 termsHash = submitLenderTerms();

    //     bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

    //     vm.prank(LENDER_ADDRESS);
    //     puree.kickoffRefinancingAuction(borrowHash);

    //     uint256 lastRate = 0;

    //     for (uint256 i = 0; i < 100; i++) {
    //         vm.roll(block.number + 1);

    //         BorrowData memory borrowData = puree.getBorrow(borrowHash);

    //         LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

    //         uint256 newRate = puree.calcRefinancingAuctionRate(
    //             puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
    //         );

    //         assertGe(newRate, lastRate);

    //         if (i == 49) assertEq(newRate, terms.interestRateBips);
    //         if (newRate == 99) assertEq(newRate, puree.LIQ_THRESHOLD());

    //         lastRate = newRate;
    //     }
    // }

    // function testSettleRefinancingAuction_invalidBorrow() public {
    //     bytes32 oldTermsHash = submitLenderTerms();

    //     bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

    //     vm.prank(LENDER_ADDRESS);
    //     puree.kickoffRefinancingAuction(borrowHash);

    //     vm.roll(block.number + 55);

    //     BorrowData memory borrowData = puree.getBorrow(borrowHash);

    //     LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

    //     uint256 newRate = puree.calcRefinancingAuctionRate(
    //         puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
    //     );

    //     assertEq(newRate, 6747);

    //     terms.interestRateBips = uint32(newRate);
    //     terms.lender = LENDER2_ADDRESS;
    //     bytes32 newTermsHash = submitLender2Terms();

    //     borrowHash = bytes32(uint256(borrowHash) + 1);

    //     vm.expectRevert("NO_ACTIVE_AUCTION");
    //     puree.settleRefinancingAuction(borrowHash, newTermsHash);
    // }

    // function testSettleRefinancingAuction_unfairTerms() public {
    //     bytes32 oldTermsHash = submitLenderTerms();

    //     bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

    //     vm.prank(LENDER_ADDRESS);
    //     puree.kickoffRefinancingAuction(borrowHash);

    //     vm.roll(block.number + 55);

    //     BorrowData memory borrowData = puree.getBorrow(borrowHash);

    //     LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

    //     uint256 newRate = puree.calcRefinancingAuctionRate(
    //         puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
    //     );

    //     assertEq(newRate, 6747);

    //     terms.interestRateBips = uint32(newRate * 2);
    //     terms.lender = LENDER2_ADDRESS;
    //     bytes32 newTermsHash = submitLender2Terms();

    //     vm.expectRevert("TERMS_NOT_REASONABLE");
    //     puree.settleRefinancingAuction(borrowHash, newTermsHash);
    // }

    // function testSettleRefinancingAuction_capacityOverflow() public {
    //     bytes32 oldTermsHash = submitLenderTerms();

    //     bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

    //     vm.prank(LENDER_ADDRESS);
    //     puree.kickoffRefinancingAuction(borrowHash);

    //     vm.roll(block.number + 55);

    //     BorrowData memory borrowData = puree.getBorrow(borrowHash);

    //     LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

    //     uint256 newRate = puree.calcRefinancingAuctionRate(
    //         puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
    //     );

    //     assertEq(newRate, 6747);

    //     terms.interestRateBips = uint32(newRate);
    //     terms.lender = LENDER2_ADDRESS;
    //     terms.totalAmount = 5e18;
    //     bytes32 newTermsHash = submitLender2Terms();

    //     vm.expectRevert("NEW_TERMS_AT_CAPACITY");
    //     puree.settleRefinancingAuction(borrowHash, newTermsHash);
    // }

    // function testSettleRefinancingAuction_termsExpired() public {
    //     bytes32 oldTermsHash = submitLenderTerms();

    //     bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

    //     vm.prank(LENDER_ADDRESS);
    //     puree.kickoffRefinancingAuction(borrowHash);

    //     vm.roll(block.number + 55);

    //     BorrowData memory borrowData = puree.getBorrow(borrowHash);

    //     LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

    //     uint256 newRate = puree.calcRefinancingAuctionRate(
    //         puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
    //     );

    //     assertEq(newRate, 6747);

    //     terms.interestRateBips = uint32(newRate);
    //     terms.lender = LENDER2_ADDRESS;
    //     bytes32 newTermsHash = submitLender2Terms();

    //     vm.warp(terms.deadline + 1 days);

    //     vm.expectRevert("TERMS_EXPIRED_OR_DO_NOT_EXIST");
    //     puree.settleRefinancingAuction(borrowHash, newTermsHash);
    // }

    // function testSettleRefinancingAuction_invalidAmount() public {
    //     bytes32 oldTermsHash = submitLenderTerms();

    //     bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

    //     vm.prank(LENDER_ADDRESS);
    //     puree.kickoffRefinancingAuction(borrowHash);

    //     vm.roll(block.number + 55);

    //     BorrowData memory borrowData = puree.getBorrow(borrowHash);

    //     LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

    //     uint256 newRate = puree.calcRefinancingAuctionRate(
    //         puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
    //     );

    //     assertEq(newRate, 6747);

    //     terms.interestRateBips = uint32(newRate);
    //     terms.maxAmount = 5e18;
    //     terms.lender = LENDER2_ADDRESS;
    //     bytes32 newTermsHash = submitLender2Terms();

    //     vm.expectRevert("INVALID_AMOUNT");
    //     puree.settleRefinancingAuction(borrowHash, newTermsHash);
    // }

    // function testSettleRefinancingAuction_insolvent() public {
    //     bytes32 oldTermsHash = submitLenderTerms();

    //     bytes32 borrowHash = puree.newBorrow(oldTermsHash, 1, 10e18);

    //     vm.prank(LENDER_ADDRESS);
    //     puree.kickoffRefinancingAuction(borrowHash);

    //     vm.roll(block.number + 100);

    //     BorrowData memory borrowData = puree.getBorrow(borrowHash);

    //     LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

    //     uint256 newRate = puree.calcRefinancingAuctionRate(
    //         puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
    //     );

    //     assertEq(newRate, puree.LIQ_THRESHOLD());

    //     terms.interestRateBips = uint32(newRate);
    //     terms.lender = LENDER2_ADDRESS;
    //     bytes32 newTermsHash = submitLender2Terms();

    //     vm.expectRevert("INSOLVENT");
    //     puree.settleRefinancingAuction(borrowHash, newTermsHash);
    // }

    /*//////////////////////////////////////////////////////////////
                               LIQUIDATION
    //////////////////////////////////////////////////////////////*/

    // function testLiquidate() public {
    //     bytes32 termsHash = submitLenderTerms();

    //     bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

    //     vm.prank(LENDER_ADDRESS);
    //     puree.kickoffRefinancingAuction(borrowHash);

    //     vm.roll(block.number + 100);

    //     BorrowData memory borrowData = puree.getBorrow(borrowHash);

    //     LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

    //     uint256 newRate = puree.calcRefinancingAuctionRate(
    //         puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
    //     );

    //     assertEq(newRate, puree.LIQ_THRESHOLD());

    //     puree.liquidate(borrowHash);

    //     assertEq(puree.getAuctionStartBlock(borrowHash), 0);

    //     assertEq(nft.ownerOf(borrowData.nftId), LENDER_ADDRESS);
    // }

    // function testLiquidate_noActiveAuction() public {
    //     bytes32 termsHash = submitLenderTerms();

    //     bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

    //     vm.expectRevert("NO_ACTIVE_AUCTION");
    //     puree.liquidate(borrowHash);
    // }

    // function testLiquidate_notInsolvent() public {
    //     bytes32 termsHash = submitLenderTerms();

    //     bytes32 borrowHash = puree.newBorrow(termsHash, 1, 10e18);

    //     vm.prank(LENDER_ADDRESS);
    //     puree.kickoffRefinancingAuction(borrowHash);

    //     vm.roll(block.number + 55);

    //     BorrowData memory borrowData = puree.getBorrow(borrowHash);

    //     LoanTerms memory termsData = puree.getTerms(borrowData.termsHash);

    //     uint256 newRate = puree.calcRefinancingAuctionRate(
    //         puree.getAuctionStartBlock(borrowHash), termsData.liquidationDurationBlocks, termsData.interestRateBips
    //     );

    //     assertEq(newRate, 6747);

    //     vm.expectRevert("NOT_INSOLVENT");
    //     puree.liquidate(borrowHash);
    // }

    /*//////////////////////////////////////////////////////////////
                            NONCE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function testBumpNonce() public {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(LENDER_PK, puree.computeOfferDigest(offer));

        assertEq(puree.getNonce(LENDER_ADDRESS), 0);

        vm.prank(LENDER_ADDRESS);
        puree.bumpNonce(1);

        assertEq(puree.getNonce(LENDER_ADDRESS), 1);

        vm.expectRevert("OFFER_EXPIRED");
        puree.newBorrow(offer, v, r, s, 1, 10e18);
    }
}
