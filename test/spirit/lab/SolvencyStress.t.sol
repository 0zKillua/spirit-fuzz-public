// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloOps} from "../../OloOps.sol";
import {MarketWord} from "../../../src/interfaces/MarketWord.sol";

/// A direct, lead-authored multi-actor lifecycle (prize-f6d75613 solvency and prize-b201485d drain): several makers
/// rest pool and batch orders on both sides, a taker crosses them, makers modify/cancel/claim, a flash runs in the
/// middle, and then everyone withdraws everything and the fee pots are collected — the contract must end empty (owing
/// no token more than it holds). A single hand-built scenario alongside the developers' fuzzers and dig-7abc6718's
/// conservation runs.
contract SolvencyStressTest is OloBase {
    function setUp() public {
        _deploy();
    }

    function test_full_lifecycle_leaves_the_book_empty() public {
        // three makers on the pool: an ask, a bid, and a second ask lower down
        address mkAsk = _plain(T, false, 10 * LOT); // ask 10 LOT at T
        address mkBid = _plain(T - 5, true, 8 * LOT); // bid 8 LOT at T-5
        address mkAsk2 = _plain(T + 2, false, 6 * LOT); // ask 6 LOT at T+2
        uint32 pAsk = posOf[mkAsk];
        uint32 pBid = posOf[mkBid];
        uint32 pAsk2 = posOf[mkAsk2];

        // a maker with a two-order batch ask ladder in slot 4
        address mkBatch = _maker();
        uint256[3] memory post = OloOps.postW(false, 4, T + 1, 5 * LOT, 2); // asks at T+1, T+2
        vm.prank(mkBatch);
        _mb(c, post);

        // the taker buys across the pool asks (bounded generously at T+10) and the batch slot
        bytes memory poolSeg = OloOps.poolList(
            bytes.concat(OloOps.poolEntry(pAsk, T + 10), OloOps.poolEntry(pAsk2, T + 10))
        );
        vm.prank(taker);
        book.take(OloOps.key(c), poolSeg, OloOps.tagW(c, OloOps.takeW(true, 7 * LOT, OloOps.WALLET)));

        bytes memory batchSeg = OloOps.batchList(OloOps.slotGroupAt(mkBatch, 4, 0x3, T + 10));
        vm.prank(taker);
        book.take(OloOps.key(c), batchSeg, OloOps.tagW(c, OloOps.takeW(true, 4 * LOT, OloOps.WALLET)));

        // the taker sells into the resting bid (bounded at T-10)
        bytes memory bidSeg = OloOps.poolList(OloOps.poolEntry(pBid, T - 10));
        vm.prank(taker);
        book.take(OloOps.key(c), bidSeg, OloOps.tagW(c, OloOps.takeW(false, 3 * LOT, OloOps.WALLET)));
        _solvent();

        // makers settle in mixed order: the ask-maker modifies (pays fills, re-rests smaller), the batch-maker claims
        // the filled sub-order, the bid-maker cancels
        vm.prank(mkAsk);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pAsk, T, 2 * LOT, 0)));
        vm.prank(mkBatch);
        _mb(c, OloOps.maskW(OloOps.CLAIM, 4, 0, 0x1)); // only sub-order 0 was filled
        vm.prank(mkBid);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pBid, 0)));
        _solvent();

        // unwind everything that still rests so the book should end exactly empty
        vm.prank(mkAsk);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pAsk, 0))); // the re-rested 2 LOT ask
        vm.prank(mkAsk2);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pAsk2, 0)));
        vm.prank(mkBatch);
        _mb(c, OloOps.maskW(OloOps.CANCEL, 4, 0, 0x3));

        // everyone withdraws both balances in full and the pots are collected: no revert here = solvent (every
        // recorded balance paid out). With every order unwound, only rounding dust — always in the contract's favour,
        // never owed to anyone — may remain, so the book is over- not under-collateralised.
        (uint256 baseLeft, uint256 quoteLeft) = _everyoneLeaves();
        assertLe(baseLeft, 100, "at most dust base left (contract's favour)");
        assertLe(quoteLeft, 100, "at most dust quote left (contract's favour)");
    }
}
