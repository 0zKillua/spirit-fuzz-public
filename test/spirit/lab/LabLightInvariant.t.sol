// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.38;

import {OloBase} from "../../OloBase.sol";
import {OloHandler, FlashActor, Mkt} from "../../OloInvariant.t.sol";
import {MockERC20} from "../../utils/MockERC20.sol";
import {MarketWord} from "../../../src/interfaces/MarketWord.sol";
import {MarketLib} from "../../../src/types/Market.sol";
import {PriceGrid} from "../../../src/libraries/PriceGrid.sol";

using MarketLib for MarketWord;

/// A lead-authored, LIGHTER copy of the developers' OloInvariant campaign (prize-f6d75613 solvency, prize-b201485d
/// drain). It reuses the developers' OloHandler verbatim (every operation, three actors, seven markets including the
/// two fee-boundary markets at 999,940 and 1,000,000 ppm) but runs at a reduced invariant config (runs/depth small
/// enough to finish inside the lab's time limit). The developers' own campaign is configured at depth 300 x 128 runs,
/// which does not complete in this environment's measurement window ("no measured results" in the minute-zero facts);
/// this file is the randomized-sequence coverage that the heavy config could not deliver here, on top of the
/// deterministic 1000-step reach test (which passes: it asserts solvency, exact-rounding and everyone-leaves-to-zero).
///
/// The two solvency-critical assertions are deliberately kept: invariant_solvent (the book holds at least every
/// account, pot and resting order's payout) has teeth over the _debit overdraw guard (OloBookAssets.sol:64 -- remove
/// it and an account over-withdraws, so owed > held); invariant_handler_checks (handler.violations == 0, which
/// recomputes every take's quote and fee in 512-bit) has teeth over the sell-side quote floor (OloBookTakes.sol:474 --
/// round a sell up and a fractional-decade sell's quote stops matching the exact down-rounded value).
contract LabLightInvariantTest is OloBase {
    OloHandler handler;
    MockERC20[] toks;
    address[3] actors;

    function setUp() public {
        _deploy();
        MockERC20 d0 = new MockERC20("Zero", "D0", 0);
        MockERC20 d6 = new MockERC20("Six", "D6", 6);
        MockERC20 d8 = new MockERC20("Eight", "D8", 8);
        MockERC20 d18 = new MockERC20("Eighteen", "D18", 18);
        MockERC20 d24 = new MockERC20("TwentyFour", "D24", 24);
        toks.push(d0);
        toks.push(d6);
        toks.push(d8);
        toks.push(d18);
        toks.push(d24);
        actors = [address(0xA11CE), address(0xB0B), address(0xCA401)];
        for (uint256 i; i < 3; ++i) {
            vm.etch(actors[i], type(FlashActor).runtimeCode);
        }
        handler = new OloHandler(book, actors, toks);
        _list(d8, d6, 200, 6, 1e6, 41, 40, 2, 10);
        _list(d18, d6, 3_000, 5, 0, 29, 600, 8, 21);
        _list(d0, d18, 0, 6, 0, 56, 30, 0, 4);
        _list(d24, d0, 500_000, 6, 0, 17, 30, 14, 27);
        _list(d6, d24, 50, 4, 1e20, 60, 3_000, 0, 9);
        _list(d6, d8, 1_000_000, 6, 0, 40, 40, 2, 10);
        _list(d18, d8, 999_940, 5, 0, 31, 600, 8, 21);
        for (uint256 i; i < 3; ++i) {
            for (uint256 t; t < toks.length; ++t) {
                toks[t].mint(actors[i], 1e40);
                vm.startPrank(actors[i]);
                toks[t].approve(address(book), type(uint256).max);
                book.deposit(address(toks[t]), 1e37);
                vm.stopPrank();
            }
        }
        book.transferOwnership(address(handler));
        handler.acceptOwnership();
        targetContract(address(handler));
        bytes4[] memory sel = new bytes4[](15);
        sel[0] = OloHandler.place.selector;
        sel[1] = OloHandler.cancel.selector;
        sel[2] = OloHandler.claim.selector;
        sel[3] = OloHandler.modify.selector;
        sel[4] = OloHandler.batch.selector;
        sel[5] = OloHandler.multicall.selector;
        sel[6] = OloHandler.deposit.selector;
        sel[7] = OloHandler.withdraw.selector;
        sel[8] = OloHandler.setShare.selector;
        sel[9] = OloHandler.collectFees.selector;
        sel[10] = OloHandler.take.selector;
        sel[11] = OloHandler.take.selector;
        sel[12] = OloHandler.takeThenRest.selector;
        sel[13] = OloHandler.setFee.selector;
        sel[14] = OloHandler.flash.selector;
        targetSelector(FuzzSelector(address(handler), sel));
    }

    function _list(
        MockERC20 b,
        MockERC20 q,
        uint24 ppm,
        uint8 sigFigs,
        uint96 minQuote,
        uint256 decade,
        uint256 spread,
        uint256 lo,
        uint256 hi
    ) internal {
        MarketWord mc = book.configOf(book.listMarketQuote(address(b), address(q), ppm, sigFigs, minQuote, 0));
        handler.addMarket(
            Mkt(mc, b, q, decade * PriceGrid.PER_DECADE, spread, PriceGrid.spacingOf(sigFigs), lo, hi, ppm)
        );
    }

    /// What the contract owes of token `t`: every account, the fee pot, and every live order's payout (a copy of the
    /// developers' OloInvariantTest._owed, so this stays an independent, self-contained check).
    function _owed(MockERC20 t) internal view returns (uint256 owed) {
        uint256 id = book.tokenId(address(t));
        for (uint256 i; i < 3; ++i) {
            owed += book.balanceOf(id, actors[i]);
        }
        owed += book.balanceOf(id, address(0));
        for (uint256 k; k < handler.marketCount(); ++k) {
            Mkt memory mm = handler.market(k);
            bool isBase = address(mm.b) == address(t);
            bool isQuote = address(mm.q) == address(t);
            if (!isBase && !isQuote) continue;
            for (uint256 p; p < handler.NSCAN(); ++p) {
                uint256 word = book.orderWord(mm.c, uint32(p));
                uint256 unit = 10 ** ((word >> 26) & 0x7f);
                owed += _payout(
                    mm,
                    isBase,
                    word & 0x3ffffff,
                    (word >> 93) & 1 == 1,
                    ((word >> 33) & ((1 << 30) - 1)) * unit,
                    ((word >> 63) & ((1 << 30) - 1)) * unit
                );
            }
            for (uint256 i; i < 3; ++i) {
                for (uint256 s; s < 2; ++s) {
                    (uint256 word, uint256 set) = book.batchOf(mm.c, actors[i], uint16(s));
                    for (uint256 j; j < 4; ++j) {
                        uint256 sub = (word >> (2 + 61 * j)) & ((1 << 61) - 1);
                        if (sub == 0) continue;
                        uint256 unit = 10 ** ((sub >> 26) & 0x1f);
                        uint256 open = sub >> 31;
                        uint256 baseUnits = (set >> (30 * j)) & ((1 << 30) - 1);
                        owed += _payout(
                            mm,
                            isBase,
                            sub & 0x3ffffff,
                            (word >> (246 + j)) & 1 == 1,
                            open * unit,
                            (baseUnits - open) * unit
                        );
                    }
                }
            }
        }
    }

    function _payout(Mkt memory mm, bool isBase, uint256 tick, bool isBid, uint256 open, uint256 filled)
        internal
        pure
        returns (uint256)
    {
        if (open == 0 && filled == 0) return 0;
        if (isBase) return isBid ? filled : open;
        uint256 fee = PriceGrid.feeDown(filled, tick, mm.ppm);
        return (isBid ? PriceGrid.quoteDown(open, tick) : PriceGrid.quoteDown(filled, tick)) + fee;
    }

    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_lab_solvent() public view {
        for (uint256 t; t < toks.length; ++t) {
            assertGe(toks[t].balanceOf(address(book)), _owed(toks[t]), string.concat("solvent: ", toks[t].symbol()));
        }
        assertEq(handler.violations(), 0, handler.lastViolation());
    }

    /// forge-config: default.invariant.fail-on-revert = false
    function invariant_lab_no_value_created() public view {
        for (uint256 t; t < toks.length; ++t) {
            MockERC20 tk = toks[t];
            uint256 held = tk.balanceOf(address(book)) + tk.balanceOf(address(this));
            for (uint256 i; i < 3; ++i) {
                held += tk.balanceOf(actors[i]);
            }
            assertEq(held, tk.totalSupply(), "every token is in a wallet or the book");
        }
    }
}
