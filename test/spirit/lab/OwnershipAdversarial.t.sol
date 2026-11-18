// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloOps} from "../../OloOps.sol";
import {IOloBookBase} from "../../../src/interfaces/IOloBookBase.sol";
import {MarketWord} from "../../../src/interfaces/MarketWord.sol";

/// Adversarial probes at order/batch/account authorization (prize-96b11e9b): an attacker tries to act on an order,
/// batch slot or account that is not theirs. The owner is the whole 160-bit address (in the pool word, in the batch
/// slot hash, folded into every account key), so no truncation/aliasing/wrong-side path should reach a victim's funds.
contract OwnershipAdversarialTest is OloBase {
    address attacker = address(0xA77ACC);

    function setUp() public {
        _deploy();
        base.mint(attacker, 1e30);
        quote.mint(attacker, 1e30);
        vm.startPrank(attacker);
        base.approve(address(book), type(uint256).max);
        quote.approve(address(book), type(uint256).max);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    /// An attacker cannot cancel a victim's live pool order: NotOrderOwner. The victim's escrow stays in the book.
    function test_attacker_cannot_cancel_victims_order() public {
        address mk = _plain(T, false, 10 * LOT); // victim rests an ask (escrows 10 LOT base)
        uint32 pos = posOf[mk];
        vm.prank(attacker);
        vm.expectRevert(IOloBookBase.NotOrderOwner.selector);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        // the victim still cancels and gets its base back
        vm.prank(mk);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        _solvent();
        _everyoneLeaves();
    }

    /// An attacker cannot claim or modify a victim's live pool order.
    function test_attacker_cannot_claim_or_modify_victims_order() public {
        address mk = _plain(T, false, 10 * LOT);
        uint32 pos = posOf[mk];
        // partially fill the victim's ask so there is something to claim
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pos, T));
        vm.prank(taker);
        book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 3 * LOT, OloOps.WALLET)));

        vm.prank(attacker);
        vm.expectRevert(IOloBookBase.NotOrderOwner.selector);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        vm.prank(attacker);
        vm.expectRevert(IOloBookBase.NotOrderOwner.selector);
        book.modify(OloOps.key(c), OloOps.tagW(c, OloOps.modifyW(pos, T, 1 * LOT, 0)));
        _solvent();
    }

    /// Reusing a victim's DEAD position does not hand the attacker the victim's fills or escrow: the attacker's fresh
    /// order owns only its own escrow, and the victim's prior fills are not claimable by the attacker.
    function test_dead_position_reuse_leaks_nothing() public {
        address mk = _plain(T, false, 10 * LOT);
        uint32 pos = posOf[mk];
        // fill part, then the victim cancels -> position goes dead (keeps USED + owner bits, order cleared)
        bytes memory list = OloOps.poolList(OloOps.poolEntry(pos, T));
        vm.prank(taker);
        book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 3 * LOT, OloOps.WALLET)));
        vm.prank(mk);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0))); // refunds open, pays fills; word dead

        uint256 potQuoteBefore = _pot(quote);
        // attacker reuses the dead position with its own small ask
        vm.prank(attacker);
        book.place(OloOps.key(c), OloOps.placeW(false, T, 1 * LOT, pos, 0));
        // the attacker has no fills to claim on the fresh order
        vm.prank(attacker);
        vm.expectRevert(IOloBookBase.NothingToClaim.selector);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        // attacker cancels: gets back exactly its own 1 LOT base, nothing of the victim's
        uint256 aBaseBefore = _bal(attacker, base);
        vm.prank(attacker);
        book.cancel(OloOps.key(c), OloOps.tagW(c, OloOps.posW(pos, 0)));
        assertEq(_bal(attacker, base) - aBaseBefore, 1 * LOT, "attacker recovers only its own escrow");
        assertEq(_pot(quote), potQuoteBefore, "no pot movement from the reuse");
        _solvent();
        _everyoneLeaves();
    }

    /// An attacker cannot grab a LIVE position another maker holds (SlotBusy), even naming probes.
    function test_attacker_cannot_squat_a_live_position() public {
        address mk = _plain(T, false, 10 * LOT);
        uint32 pos = posOf[mk];
        vm.prank(attacker);
        vm.expectRevert(IOloBookBase.SlotBusy.selector);
        book.place(OloOps.key(c), OloOps.placeW(false, T, 1 * LOT, pos, 0));
        _solvent();
    }

    /// An attacker cannot settle a victim's batch slot as if it were the attacker's own: the slot hash binds the
    /// maker address, so the attacker's own (maker, slot) is a different, empty slot (NoOrder on cancel/claim).
    function test_attacker_cannot_settle_victims_batch_slot() public {
        address victim = _maker();
        // victim posts a 2-order ask ladder in batch slot 7
        uint256[3] memory post = OloOps.postW(false, 7, T, 5 * LOT, 2);
        vm.prank(victim);
        _mb(c, post);
        // attacker's own slot 7 is empty: a cancel there reverts NoOrder (it is NOT the victim's)
        uint256[3] memory cancelAll = OloOps.maskW(OloOps.CANCEL, 7, 0, 0x3);
        vm.prank(attacker);
        vm.expectRevert(IOloBookBase.NoOrder.selector);
        _mb(c, cancelAll);
        // the victim's slot is intact: the victim cancels and the book stays solvent
        vm.prank(victim);
        _mb(c, cancelAll);
        _solvent();
        _everyoneLeaves();
    }

    /// A taker filling a victim's batch slot (which is the normal, allowed action) moves only the taker's own quote
    /// and the slot's open units; it cannot overdraw the victim's other slots or accounts.
    function test_taking_a_batch_slot_touches_only_that_slot() public {
        address victim = _maker();
        uint256[3] memory post = OloOps.postW(false, 9, T, 5 * LOT, 2); // asks at T and T+1
        vm.prank(victim);
        _mb(c, post);
        uint256 vQuoteBefore = _bal(victim, quote);
        uint256 vBaseBefore = _bal(victim, base);
        // attacker buys 3 LOT from the victim's slot 9, sub-order 0 (tick T), bounded at T
        bytes memory group = OloOps.slotGroupAt(victim, 9, 0x1, T);
        bytes memory list = OloOps.batchList(group);
        vm.prank(attacker);
        book.take(OloOps.key(c), list, OloOps.tagW(c, OloOps.takeW(true, 3 * LOT, OloOps.WALLET)));
        // the victim's accounts are unchanged by a take (fills accrue in the slot, paid on settle)
        assertEq(_bal(victim, quote), vQuoteBefore, "victim quote untouched by a take");
        assertEq(_bal(victim, base), vBaseBefore, "victim base untouched by a take");
        _solvent();
        _everyoneLeaves();
    }
}
