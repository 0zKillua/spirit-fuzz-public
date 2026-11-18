// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloOps} from "../../OloOps.sol";
import {IOloBookBase} from "../../../src/interfaces/IOloBookBase.sol";
import {MarketWord} from "../../../src/interfaces/MarketWord.sol";
import {SettleFlags} from "../../../src/libraries/Flags.sol";

/// Session 9: the second reader's open gaps. Each item below was closed by the prior lead on an argument, never on a
/// test name. This file turns the arguments into executed negatives.
///
///  - inbox-dcde93f4: the GasBench family (105 fail) never executed in this lab -> the hot take-walk has no lab test.
///    Replicate GasBenchOlo's warm setUp and its N-order take WITHOUT the `vm.lastFrameGas()` gas cheatcode (that
///    cheatcode is the only thing the GasBench rows add over OloBookTest, and it reverts unless forge runs --isolate;
///    `isolate` is not set in foundry.toml, so the minute-zero whole-suite run reverted every row). If the contract
///    hot path is sound, the walk executes and stays solvent here.
///  - inbox-bc75e8e9 (part): `_commit`'s AUTO netting of a WITHDRAW against a same-token maker escrow debit. The
///    account funds the escrow from its balance AFTER the call's own credits/withdrawals leave it, the rest from the
///    wallet, and every pull precedes every push. No test named this path.
///  - inbox-3cd60f86: the take loop re-reads each pool word per list entry, so a list naming the same position twice
///    fills it twice from the DECREMENTED open -- it can never pay out more base than the order escrowed.
contract SecondReaderGapsTest is OloBase {
    function setUp() public {
        _deploy();
        vm.startPrank(taker);
        book.deposit(address(base), 1e24);
        book.deposit(address(quote), 1e24);
        vm.stopPrank();
    }

    uint256 internal constant WALLET_TAKE = 0x01; // OloOps take mode: pay from the wallet

    // --------------------------------------------------------------- GasBench hot path (no gas cheatcode)

    /// GasBenchOlo.setUp warms the pot (one past round) and rests 3 asks + 3 bids at 5 LOT; the `test_take_N` rows then
    /// walk a buy across N asks. Here: warm the pot, rest 6 asks across a decade, and take a buy that walks all six.
    /// The only thing dropped vs the GasBench row is `_gas()`/`_receipt()` (vm.lastFrameGas), which needs --isolate.
    function test_gasbench_hot_take_walk_executes_and_stays_solvent() public {
        // warm the pot exactly as GasBenchOlo.setUp does: a 1-LOT ask at T+1, taken, then claimed
        address w = _plain(T + 1, false, 1 * LOT);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(w)), OloOps.tagW(c, OloOps.takeW(true, 1 * LOT, 0)));
        vm.prank(w);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[w], 0)));
        assertGt(_pot(quote), 0, "pot not warmed");

        // six asks across the decade, each 5 LOT
        address[6] memory asks;
        bytes memory entries;
        for (uint256 i; i < 6; ++i) {
            asks[i] = _plain(T + 1 + i, false, 5 * LOT);
            entries = bytes.concat(entries, _poolEntry(asks[i]));
        }

        uint256 takerBaseBefore = _bal(taker, base);
        // a buy that wants exactly the six asks' total base (30 LOT): the walk fills every ask
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(true, 30 * LOT, 0)));

        // the taker received base from the multi-order walk; the whole hot path executed
        uint256 got = _bal(taker, base) - takerBaseBefore;
        assertGt(got, 0, "walk filled nothing");
        assertLe(got, 30 * LOT, "walk filled more than the asks' escrow");
        _solvent();

        // every maker claims its proceeds, then everyone withdraws in full and only the pots remain
        for (uint256 i; i < 6; ++i) {
            vm.prank(asks[i]);
            book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[asks[i]], 0)));
        }
        _solvent();
        // _everyoneLeaves withdraws every account in full: it reverts if the contract owes more than it holds
        _everyoneLeaves();
    }

    /// Diag A: warm + six asks + the 30-LOT walk, stopping at _solvent (no claims, no _everyoneLeaves).
    function test_diag_A_walk_then_solvent() public {
        address w = _plain(T + 1, false, 1 * LOT);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(w)), OloOps.tagW(c, OloOps.takeW(true, 1 * LOT, 0)));
        vm.prank(w);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[w], 0)));
        bytes memory entries;
        for (uint256 i; i < 6; ++i) {
            entries = bytes.concat(entries, _poolEntry(_plain(T + 1 + i, false, 5 * LOT)));
        }
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(true, 30 * LOT, 0)));
        _solvent();
    }

    /// Diag B: Diag A but also _everyoneLeaves (no explicit claims first).
    function test_diag_B_walk_then_leaves() public {
        address w = _plain(T + 1, false, 1 * LOT);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(w)), OloOps.tagW(c, OloOps.takeW(true, 1 * LOT, 0)));
        vm.prank(w);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[w], 0)));
        bytes memory entries;
        for (uint256 i; i < 6; ++i) {
            entries = bytes.concat(entries, _poolEntry(_plain(T + 1 + i, false, 5 * LOT)));
        }
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(entries), OloOps.tagW(c, OloOps.takeW(true, 30 * LOT, 0)));
        _everyoneLeaves();
    }

    // --------------------------------------------------------------- _commit AUTO netting (withdraw vs escrow)

    /// AUTO multicall on ONE token: a WITHDRAW of W base and a PLACE escrowing E base, same account. The escrow is
    /// funded from the account's balance after the withdraw leaves it; the account ends at B - W - E, the wallet nets a
    /// single push of W, and the order holds E. Solvent, and the maker leaves whole.
    function test_commit_auto_nets_withdraw_against_same_token_escrow() public {
        address a = _maker(); // deposits 1e24 base and 1e24 quote
        uint256 id = book.tokenId(address(base));
        uint256 B = _bal(a, base);
        uint256 W = 3 * LOT;
        uint256 E = 5 * LOT;
        uint256 walletBefore = base.balanceOf(a);

        bytes memory ops = bytes.concat(
            OloOps.withdraw(id, uint128(W)),
            OloOps.place(0, T + 1, false, E, _pos())
        );
        vm.prank(a);
        book.multicall(SettleFlags.AUTO, _mc(ops));

        // account paid both the withdraw and the escrow out of its balance
        assertEq(_bal(a, base), B - W - E, "account not debited W + E");
        // the wallet received exactly the withdraw (the escrow came from the account, not a wallet pull)
        assertEq(base.balanceOf(a) - walletBefore, W, "wallet did not net to a single W push");
        _solvent();
        _everyoneLeaves();
    }

    /// AUTO where the withdraw leaves the account short of the escrow, so the shortfall is pulled from the wallet, and
    /// the whole thing still nets to one wallet move. Fresh account funded with only D base in the book.
    function test_commit_auto_withdraw_forces_wallet_to_fund_escrow_shortfall() public {
        address a = address(0xD00D);
        base.mint(a, 1e30);
        quote.mint(a, 1e30);
        vm.startPrank(a);
        base.approve(address(book), type(uint256).max);
        quote.approve(address(book), type(uint256).max);
        uint256 D = 10 * LOT;
        book.deposit(address(base), D); // account base = 10 LOT
        vm.stopPrank();
        makers.push(a); // so _everyoneLeaves sweeps it

        uint256 id = book.tokenId(address(base));
        uint256 W = 8 * LOT; // withdraw 8 -> 2 LOT left for the escrow
        uint256 E = 5 * LOT; // escrow 5 -> 3 LOT short, pulled from the wallet
        uint256 walletBefore = base.balanceOf(a);
        uint256 contractBefore = base.balanceOf(address(book));

        bytes memory ops = bytes.concat(
            OloOps.withdraw(id, uint128(W)),
            OloOps.place(0, T + 1, false, E, _pos())
        );
        vm.prank(a);
        book.multicall(SettleFlags.AUTO, _mc(ops));

        // the account is drained to 0 (its whole 10 LOT went: 2 to the escrow, 8 to the withdraw)
        assertEq(_bal(a, base), 0, "account not drained to zero");
        // net wallet move = +W (withdraw) - (E - (D - W)) (escrow shortfall) = D - E = 5 LOT pushed
        assertEq(base.balanceOf(a) - walletBefore, D - E, "wallet net move wrong");
        // the contract now holds exactly D - (D - E) = E more than... check via solvency instead
        assertEq(base.balanceOf(address(book)), contractBefore - (D - E), "contract balance moved wrong");
        _solvent();
        _everyoneLeaves();
    }

    // --------------------------------------------------------------- take list naming the same position twice

    /// A pool list naming the same position twice: the loop re-loads the word on the second entry, sees open == 0
    /// (the first entry filled it whole), and skips it. The order pays out exactly its escrow once; the leftover walks
    /// off. A double-fill would pay out 2x the escrow and show as insolvency here.
    function test_take_list_same_position_twice_cannot_double_fill() public {
        address maker = _plain(T, false, 10 * LOT); // one ask, 10 LOT base escrowed
        uint256 takerBaseBefore = _bal(taker, base);
        uint256 makerQuoteBefore = _bal(maker, quote);

        // the SAME pool entry twice in one list
        bytes memory doubled = bytes.concat(_poolEntry(maker), _poolEntry(maker));
        // a buy wanting 15 LOT: the first entry fills the whole 10 LOT open, the second sees open 0 and is skipped
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(doubled), OloOps.tagW(c, OloOps.takeW(true, 15 * LOT, 0)));

        // the taker got exactly the order's 10 LOT, not 20
        assertEq(_bal(taker, base) - takerBaseBefore, 10 * LOT, "double fill: taker received more than the escrow");
        _solvent();

        // the order is dead now; the maker claims its fills (proceeds are realized on claim, not at fill time)
        vm.prank(maker);
        book.claim(OloOps.key(c), OloOps.tagW(c, OloOps.posW(posOf[maker], 0)));
        assertGt(_bal(maker, quote) - makerQuoteBefore, 0, "maker received no proceeds");
        _solvent();
        _everyoneLeaves();
    }

    /// Control: the same order, the same list shape but naming the position ONCE, fills the same 10 LOT -- proving the
    /// second entry above added nothing rather than the order being short.
    function test_take_list_single_entry_control() public {
        address maker = _plain(T, false, 10 * LOT);
        uint256 takerBaseBefore = _bal(taker, base);
        vm.prank(taker);
        book.take(OloOps.key(c), OloOps.poolList(_poolEntry(maker)), OloOps.tagW(c, OloOps.takeW(true, 15 * LOT, 0)));
        assertEq(_bal(taker, base) - takerBaseBefore, 10 * LOT, "single entry did not fill the whole order");
        _solvent();
        _everyoneLeaves();
    }
}
