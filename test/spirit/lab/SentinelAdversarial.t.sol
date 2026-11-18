// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloSentinelBase} from "../../OloSentinelBase.sol";
import {IOloSentinel} from "../../../sentinel/IOloSentinel.sol";
import {IOloBookExt} from "../../../src/interfaces/IOloBookExt.sol";
import {IOwned2Step} from "../../../src/interfaces/IOwned2Step.sol";
import {MarketLib} from "../../../src/types/Market.sol";
import {MarketWord} from "../../../src/interfaces/MarketWord.sol";

/// Adversarial probes at the sentinel timelock (prize-17b264c6): the handover/stale-op path and the once-per-delay
/// / before-delay guards, which the developers' sentinel invariant handler never schedules for (it fuzzes only
/// fee/floor ops in a single ownership stretch).
contract SentinelAdversarialTest is OloSentinelBase {
    using MarketLib for MarketWord;

    uint256 constant STEP = 10_000; // MarketLib.MAX_FEE_STEP_PPM (1% of PPM)

    function setUp() public {
        _deploySentinelFixture();
    }

    /// An op scheduled in one stretch of ownership must not run after the sentinel loses and regains the book: the
    /// handover banks no op. ATTACK: admin schedules a fee op, the book is handed to a third party and proposed back,
    /// and the admin tries to execute the pre-handover op at a valid time. It must revert NotScheduled (stale).
    function test_stale_op_after_handover_cannot_execute() public {
        uint256 fee0 = book.configOf(m).feePpm();
        // admin schedules a fee bump in the current stretch, does NOT execute it
        bytes memory feeOp = _fee(m, fee0 + STEP);
        uint256 eta = _schedule(feeOp);

        // hand the book out to this test contract (a scheduled transferOwnership op), then take it back directly,
        // and have the sentinel accept: a new stretch begins, _ownedSince advances
        _scheduleAndRun(_bookOwner(address(this)));
        book.acceptOwnership(); // this contract now owns the book
        assertEq(book.owner(), address(this), "intermediate owner holds the book");
        book.transferOwnership(address(sentinel));
        vm.prank(address(0xA11));
        sentinel.acceptBookOwnership(); // held==false -> _ownedSince = now; the old op is stale

        // at a time well within the original op's window, the pre-handover op is refused as stale
        vm.warp(eta + 1);
        bytes[] memory one = _one(feeOp);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotScheduled.selector, _feeKey(m)));
        sentinel.execute(one);
    }

    /// Control: with no handover, that same fee op executes and moves the fee exactly one step.
    function test_control_fee_op_runs_without_handover() public {
        uint256 fee0 = book.configOf(m).feePpm();
        _scheduleAndRun(_fee(m, fee0 + STEP));
        assertEq(book.configOf(m).feePpm(), fee0 + STEP, "fee moved one step");
    }

    /// A key cannot be re-scheduled while its op is still live: a second schedule of the same key reverts KeyPending,
    /// so one key holds one pending op at a time.
    function test_same_key_cannot_be_double_scheduled() public {
        uint256 fee0 = book.configOf(m).feePpm();
        _schedule(_fee(m, fee0 + STEP));
        bytes[] memory again = _one(_fee(m, fee0 + 1)); // same selector+market => same key, different value
        vm.prank(ADMIN);
        vm.expectRevert(); // KeyPending(key)
        sentinel.schedule(again);
    }

    /// To move a fee a second 1% needs a second full delay: after an op executes (its key freed), the re-scheduled op
    /// cannot run at the first op's eta. So two steps take two delays, never one.
    function test_second_step_needs_a_second_delay() public {
        uint256 fee0 = book.configOf(m).feePpm();
        _scheduleAndRun(_fee(m, fee0 + STEP)); // first +1% at delay 1
        // re-schedule the same key for a second +1%; its eta is a fresh delay away
        bytes memory op2 = _fee(m, fee0 + 2 * STEP);
        vm.prank(ADMIN);
        uint256 eta2 = sentinel.schedule(_one(op2));
        // executing before the new eta is refused: the second step cannot land in the first delay
        bytes[] memory one = _one(op2);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotReady.selector, _feeKey(m), eta2));
        sentinel.execute(one);
        // at the new eta it runs: the second step is a whole delay after the first
        vm.warp(eta2);
        _execute(op2);
        assertEq(book.configOf(m).feePpm(), fee0 + 2 * STEP, "two steps took two delays");
    }

    /// The guardian cannot cancel a pending setGuardian op (a guardian change is the admin's alone): the guardian
    /// cannot hold off its own replacement.
    function test_guardian_cannot_cancel_its_own_replacement() public {
        bytes memory op = _guardian(address(0xDEAD));
        _schedule(op);
        bytes32 key = keccak256(abi.encode(IOloSentinel.setGuardian.selector));
        bytes32[] memory keys = _keys(key);
        vm.prank(GUARDIAN);
        vm.expectRevert(IOloSentinel.NotCanceller.selector);
        sentinel.cancel(keys);
        // the admin may, proving the op and key are real
        vm.prank(ADMIN);
        sentinel.cancel(keys);
    }

    /// An own-settings function cannot be called directly, bypassing the timelock: only an executed op (msg.sender ==
    /// the sentinel) runs it.
    function test_own_settings_not_callable_directly() public {
        vm.prank(ADMIN);
        vm.expectRevert(IOloSentinel.NotSelf.selector);
        sentinel.setDelay(2 days);
        vm.prank(ADMIN);
        vm.expectRevert(IOloSentinel.NotSelf.selector);
        sentinel.setGuardian(address(0xDEAD));
        vm.prank(ADMIN);
        vm.expectRevert(IOloSentinel.NotSelf.selector);
        sentinel.transferAdmin(address(0xDEAD));
    }

    /// An op cannot execute before its eta even by one second (basic timelock).
    function test_execute_before_eta_reverts() public {
        uint256 fee0 = book.configOf(m).feePpm();
        bytes memory op = _fee(m, fee0 + STEP);
        uint256 eta = _schedule(op);
        vm.warp(eta - 1);
        bytes[] memory one = _one(op);
        vm.prank(ADMIN);
        vm.expectRevert(abi.encodeWithSelector(IOloSentinel.NotReady.selector, _feeKey(m), eta));
        sentinel.execute(one);
    }

    function _feeKey(uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(IOloBookExt.setMarketFee.selector, id));
    }
}
