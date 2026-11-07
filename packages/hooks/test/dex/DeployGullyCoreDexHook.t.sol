// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
// Copyright (C) 2026 Gully Labs (modifications: Gully Core)
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CreateXTest} from "../helpers/CreateXLike.sol";
import {DeployGullyCoreDexHookScript, DexGullyCoreMetadata} from "../../script/DeployGullyCoreDexHook.s.sol";
import {GullyCoreDexHook} from "../../src/dex/GullyCoreDexHook.sol";

contract DexRegistryStub {
    mapping(address => bool) public isRegistered;
    mapping(address => address) public stewardOf;

    function register(address hook, DexGullyCoreMetadata calldata) external {
        require(!isRegistered[hook], "already");
        isRegistered[hook] = true;
        stewardOf[hook] = msg.sender;
    }

    function transferSteward(address hook, address next) external {
        require(stewardOf[hook] == msg.sender, "not steward");
        stewardOf[hook] = next;
    }
}

contract DexSafeStandIn {}

contract DeployGullyCoreDexHookTest is Test, Deployers {
    uint256 internal constant PK = 0xA11CE;
    address internal constant OPS = address(0x0B5);
    address internal deployer;
    address internal safe;
    CLPoolManager internal manager;
    DexRegistryStub internal registry;
    DeployGullyCoreDexHookScript internal script;

    function setUp() public {
        deployer = vm.addr(PK);
        CreateXTest.etch();
        (, manager) = createFreshManager();
        registry = new DexRegistryStub();
        safe = address(new DexSafeStandIn());
        script = new DeployGullyCoreDexHookScript();
    }

    function _p() internal view returns (DeployGullyCoreDexHookScript.Params memory) {
        return DeployGullyCoreDexHookScript.Params({
            pk: PK,
            poolManager: ICLPoolManager(address(manager)),
            owner: safe,
            recipient: safe,
            registry: address(registry),
            steward: OPS,
            feeCap: 50_000,
            shareBps: 1_500,
            maxShareBps: 3_000,
            shareNotice: 7 days,
            tunerNotice: 1 days,
            maxMove: 500,
            oracleMaxTickDelta: 100,
            oracleMinWindow: 600,
            oracleInitialCardinality: 16,
            target: CreateXTest.target(deployer, bytes11("dex"))
        });
    }

    function test_deploys_readsBack_underEip170_listsWithStewardOps() public {
        GullyCoreDexHook hook = script.runWith(_p());
        assertEq(hook.owner(), safe);
        assertEq(hook.protocolRecipient(), safe);
        assertEq(hook.FEE_CAP(), 50_000);
        assertEq(hook.ORACLE_MIN_WINDOW_SECONDS(), 600);
        assertLe(address(hook).code.length, 24_576, "EIP-170 at the pinned 2,000 runs");
        assertTrue(registry.isRegistered(address(hook)));
        assertEq(registry.stewardOf(address(hook)), OPS);
    }

    function test_refusesAnEoaOwner() public {
        DeployGullyCoreDexHookScript.Params memory p = _p();
        p.owner = address(0xE0A);
        vm.expectRevert(bytes("DEX_OWNER has no code - the Safe, not an EOA"));
        script.runWith(p);
    }

    function test_onProduction_refusesAnOwnerThatIsNotTheSafeOfRecord() public {
        vm.chainId(485590);
        vm.expectRevert(bytes("DEX_OWNER is not the governance Safe of record"));
        script.checkInputs(_p(), deployer);
    }

    function test_refusesASecondDeployAtTheSameSalt() public {
        script.runWith(_p());
        vm.expectRevert(bytes("the predicted address already has code on this chain (GULLYCORE_DEX_HOOK)"));
        script.runWith(_p());
    }
}
