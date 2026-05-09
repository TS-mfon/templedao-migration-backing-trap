// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../src/TempleMigrationBackingRegistry.sol";
import "../src/TempleMigrationBackingTrap.sol";
import "../src/TempleMigrationRiskResponse.sol";
import "../src/TempleTelegramAlertSink.sol";
import "../src/TempleTypes.sol";
import {FakeOldStaking as FakeOldStakingV2} from "../src/mocks/FakeOldStaking.sol";
import {GoodOldStaking as GoodOldStakingV2} from "../src/mocks/GoodOldStaking.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockTempleFraxPair} from "../src/mocks/MockTempleFraxPair.sol";
import {TempleMigrationAttackerV2} from "../src/mocks/TempleMigrationAttackerV2.sol";
import {TempleStaxMigrationMockV2} from "../src/mocks/TempleStaxMigrationMockV2.sol";

interface Vm {
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function store(address target, bytes32 slot, bytes32 value) external;
    function roll(uint256 blockNumber) external;
    function prank(address sender) external;
    function expectRevert(bytes4 selector) external;
    function expectRevert() external;
}

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract FakeOldStaking {
    function migrateWithdraw(address, uint256) external {}
}

contract GoodOldStaking {
    MockToken public immutable token;

    constructor(MockToken token_) {
        token = token_;
    }

    function migrateWithdraw(address, uint256 amount) external {
        token.transfer(msg.sender, amount);
    }
}

contract TempleStaxLikeMock {
    MockToken public immutable token;
    address public responseExecutor;
    bool public paused;
    uint256 public totalCreditedStake;
    uint256 public lastMigrationAmount;
    uint256 public lastBackingBefore;
    uint256 public lastBackingAfter;
    address public lastMigrationOldStaking;
    address public lastMigrator;
    mapping(address => uint256) public credited;
    mapping(address => bool) public trustedOldStaking;

    error Paused();
    error OnlyResponse();

    constructor(MockToken token_) {
        token = token_;
    }

    function setResponseExecutor(address executor) external {
        responseExecutor = executor;
    }

    function setTrustedOldStaking(address oldStaking, bool trusted) external {
        trustedOldStaking[oldStaking] = trusted;
    }

    function seedStake(address staker, uint256 amount) external {
        credited[staker] += amount;
        totalCreditedStake += amount;
    }

    function migrateStake(address oldStaking, uint256 amount) external {
        uint256 backingBefore = token.balanceOf(address(this));
        FakeOldStaking(oldStaking).migrateWithdraw(msg.sender, amount);
        uint256 backingAfter = token.balanceOf(address(this));
        credited[msg.sender] += amount;
        totalCreditedStake += amount;
        lastMigrationOldStaking = oldStaking;
        lastMigrator = msg.sender;
        lastMigrationAmount = amount;
        lastBackingBefore = backingBefore;
        lastBackingAfter = backingAfter;
    }

    function withdrawAll(bool) external {
        if (paused) revert Paused();
        uint256 amount = credited[msg.sender];
        credited[msg.sender] = 0;
        totalCreditedStake -= amount;
        token.transfer(msg.sender, amount);
    }

    function emergencyPause() external virtual {
        if (msg.sender != responseExecutor) revert OnlyResponse();
        paused = true;
    }

    function templeMigrationMetrics() external view returns (TempleTypes.Metrics memory) {
        return TempleTypes.Metrics({
            creditedStake: totalCreditedStake,
            tokenBacking: token.balanceOf(address(this)),
            lastMigrationAmount: lastMigrationAmount,
            lastBackingBefore: lastBackingBefore,
            lastBackingAfter: lastBackingAfter,
            lastMigrationOldStaking: lastMigrationOldStaking,
            lastMigrator: lastMigrator,
            oldStakingTrusted: trustedOldStaking[lastMigrationOldStaking],
            paused: paused
        });
    }
}

contract FailingPauseTarget is TempleStaxLikeMock {
    constructor(MockToken token_) TempleStaxLikeMock(token_) {}

    function emergencyPause() external pure override {
        revert("pause failed");
    }
}

contract TempleMigrationBackingTrapTest {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address internal constant REGISTRY_ADDR = 0x0000000000000000000000000000000000007101;
    address internal constant DROSERA = address(0xD005E7A);
    address internal constant ATTACKER = address(0xA77A);
    bytes32 internal constant ENV = keccak256("TEMPLEDAO_STAX_ETHEREUM");

    MockToken internal token;
    TempleStaxLikeMock internal staking;
    TempleMigrationBackingRegistry internal registry;
    TempleMigrationRiskResponse internal response;

    function setUp() public {
        token = new MockToken();
        staking = new TempleStaxLikeMock(token);
        registry = new TempleMigrationBackingRegistry(ENV, address(staking), address(1), true);
        response = new TempleMigrationRiskResponse(DROSERA, address(registry), address(0), 2);
        registry.setConfig(ENV, address(staking), address(response), true);
        staking.setResponseExecutor(address(response));
        token.mint(address(staking), 1_000 ether);
        staking.seedStake(address(0xC0FFEE), 1_000 ether);
        _installRegistryForTrap(address(registry), ENV, address(staking), address(response), true);
        vm.roll(100);
    }

    function testHealthyWindowDoesNotTrigger() public {
        TempleMigrationBackingTrap trap = new TempleMigrationBackingTrap();
        bytes[] memory data = _collectWindow(trap);
        (bool ok,) = trap.shouldRespond(data);
        _assertFalse(ok, "healthy state should not trigger");
    }

    function testInsufficientSamplesDoNotTrigger() public {
        TempleMigrationBackingTrap trap = new TempleMigrationBackingTrap();
        bytes[] memory data = new bytes[](2);
        data[1] = trap.collect();
        vm.roll(101);
        data[0] = trap.collect();
        (bool ok,) = trap.shouldRespond(data);
        _assertFalse(ok, "insufficient samples");
    }

    function testSingleAnomalousSampleTriggersBecauseExploitStageIsActionable() public {
        TempleMigrationBackingTrap trap = new TempleMigrationBackingTrap();
        bytes[] memory data = new bytes[](3);
        data[2] = trap.collect();
        vm.roll(101);
        data[1] = trap.collect();
        _stageFakeMigration();
        vm.roll(102);
        data[0] = trap.collect();

        (bool ok, bytes memory payload) = trap.shouldRespond(data);
        _assertTrue(ok, "unbacked migration credit should trigger");
        TempleTypes.Incident memory incident = abi.decode(payload, (TempleTypes.Incident));
        _assertTrue((incident.reasonBitmap & TempleTypes.REASON_UNBACKED_STAKE) != bytes32(0), "unbacked stake reason");
        _assertTrue((incident.reasonBitmap & TempleTypes.REASON_UNTRUSTED_MIGRATOR) != bytes32(0), "untrusted migrator reason");
        _assertTrue(
            (incident.reasonBitmap & TempleTypes.REASON_MIGRATION_WITHOUT_BACKING_INFLOW) != bytes32(0),
            "missing backing inflow reason"
        );
    }

    function testSampleOrderingIsAlertOnly() public {
        TempleMigrationBackingTrap trap = new TempleMigrationBackingTrap();
        bytes[] memory data = _collectWindow(trap);
        bytes[] memory reversed = new bytes[](3);
        reversed[0] = data[2];
        reversed[1] = data[1];
        reversed[2] = data[0];
        (bool respond,) = trap.shouldRespond(reversed);
        _assertFalse(respond, "bad ordering must not pause");
        (bool ok, bytes memory payload) = trap.shouldAlert(reversed);
        _assertTrue(ok, "bad ordering should alert");
        TempleTypes.Incident memory incident = abi.decode(payload, (TempleTypes.Incident));
        _assertTrue((incident.reasonBitmap & TempleTypes.REASON_INVALID_SAMPLE_WINDOW) != bytes32(0), "ordering reason");
    }

    function testMalformedSchemaIsAlertOnly() public {
        TempleMigrationBackingTrap trap = new TempleMigrationBackingTrap();
        bytes[] memory data = _collectWindow(trap);
        TempleTypes.CollectOutput memory malformed = abi.decode(data[0], (TempleTypes.CollectOutput));
        malformed.schemaVersion = 99;
        data[0] = abi.encode(malformed);
        (bool respond,) = trap.shouldRespond(data);
        _assertFalse(respond, "malformed schema must not pause");
        (bool ok, bytes memory payload) = trap.shouldAlert(data);
        _assertTrue(ok, "malformed schema should alert");
        TempleTypes.Incident memory incident = abi.decode(payload, (TempleTypes.Incident));
        _assertTrue((incident.reasonBitmap & TempleTypes.REASON_INVALID_METRICS) != bytes32(0), "malformed reason");
    }

    function testMalformedShortBytesDoNotRevert() public {
        TempleMigrationBackingTrap trap = new TempleMigrationBackingTrap();
        bytes[] memory data = new bytes[](3);
        data[0] = hex"1234";
        data[1] = hex"5678";
        data[2] = hex"90";
        (bool respond,) = trap.shouldRespond(data);
        _assertFalse(respond, "short bytes must not pause");
        (bool alert,) = trap.shouldAlert(data);
        _assertTrue(alert, "short bytes should alert");
    }

    function testRegistryInactiveCollectIsExplicit() public {
        _installRegistryForTrap(address(registry), ENV, address(staking), address(response), false);
        TempleMigrationBackingTrap trap = new TempleMigrationBackingTrap();
        TempleTypes.CollectOutput memory out = abi.decode(trap.collect(), (TempleTypes.CollectOutput));
        _assertTrue(out.status == TempleTypes.STATUS_REGISTRY_INACTIVE, "inactive status");
    }

    function testTargetMissingCollectIsExplicit() public {
        _installRegistryForTrap(address(registry), ENV, address(0xBEEF), address(response), true);
        TempleMigrationBackingTrap trap = new TempleMigrationBackingTrap();
        TempleTypes.CollectOutput memory out = abi.decode(trap.collect(), (TempleTypes.CollectOutput));
        _assertTrue(out.status == TempleTypes.STATUS_TARGET_MISSING, "missing target status");
    }

    function testMetricsCallFailureIsExplicit() public {
        _installRegistryForTrap(address(registry), ENV, address(new FakeOldStaking()), address(response), true);
        TempleMigrationBackingTrap trap = new TempleMigrationBackingTrap();
        TempleTypes.CollectOutput memory out = abi.decode(trap.collect(), (TempleTypes.CollectOutput));
        _assertTrue(out.status == TempleTypes.STATUS_METRICS_CALL_FAILED, "metrics failure status");
        bytes[] memory data = _repeatSample(abi.encode(out));
        (bool respond,) = trap.shouldRespond(data);
        _assertFalse(respond, "metrics failure must not pause");
        (bool alert,) = trap.shouldAlert(data);
        _assertTrue(alert, "metrics failure should alert");
    }

    function testAlreadyPausedTargetDoesNotRetrigger() public {
        TempleMigrationBackingTrap trap = new TempleMigrationBackingTrap();
        _stageFakeMigration();
        _handle(trap);
        bytes[] memory data = _collectWindow(trap);
        (bool ok,) = trap.shouldRespond(data);
        _assertFalse(ok, "already paused target");
    }

    function testHistoricalDangerousPathWithoutResponseDrainsBacking() public {
        _stageFakeMigration();
        uint256 beforeBalance = token.balanceOf(ATTACKER);
        vm.prank(ATTACKER);
        staking.withdrawAll(false);
        _assertTrue(token.balanceOf(ATTACKER) > beforeBalance, "attacker extracted LP backing");
    }

    function testResponsePausesAndBlocksWithdrawCompletion() public {
        TempleMigrationBackingTrap trap = new TempleMigrationBackingTrap();
        _stageFakeMigration();
        _handle(trap);

        vm.prank(ATTACKER);
        bool reverted;
        try staking.withdrawAll(false) {}
        catch {
            reverted = true;
        }
        _assertTrue(reverted, "withdraw completion blocked");
        _assertTrue(token.balanceOf(ATTACKER) == 0, "attacker balance remains zero");
    }

    function testWrongCallerCannotExecuteResponse() public {
        TempleTypes.Incident memory incident = _sampleIncident(address(staking), ENV);
        vm.expectRevert(TempleMigrationRiskResponse.OnlyDrosera.selector);
        response.handleIncident(incident);
    }

    function testWrongInvariantRejected() public {
        TempleTypes.Incident memory incident = _sampleIncident(address(staking), ENV);
        incident.invariantId = bytes32(uint256(123));
        vm.prank(DROSERA);
        vm.expectRevert(TempleMigrationRiskResponse.WrongInvariant.selector);
        response.handleIncident(incident);
    }

    function testWrongEnvironmentRejected() public {
        TempleTypes.Incident memory incident = _sampleIncident(address(staking), keccak256("WRONG"));
        vm.prank(DROSERA);
        vm.expectRevert(TempleMigrationRiskResponse.WrongEnvironment.selector);
        response.handleIncident(incident);
    }

    function testWrongTargetRejected() public {
        TempleTypes.Incident memory incident = _sampleIncident(address(0xBEEF), ENV);
        vm.prank(DROSERA);
        vm.expectRevert(TempleMigrationRiskResponse.WrongTarget.selector);
        response.handleIncident(incident);
    }

    function testWrongResponseExecutorRejected() public {
        registry.setConfig(ENV, address(staking), address(0xBAD), true);
        TempleTypes.Incident memory incident = _sampleIncident(address(staking), ENV);
        vm.prank(DROSERA);
        vm.expectRevert(TempleMigrationRiskResponse.WrongResponseExecutor.selector);
        response.handleIncident(incident);
    }

    function testNonActionableIncidentRejected() public {
        TempleTypes.Incident memory incident = _sampleIncident(address(staking), ENV);
        incident.reasonBitmap = TempleTypes.REASON_INVALID_SAMPLE_WINDOW;
        vm.prank(DROSERA);
        vm.expectRevert(TempleMigrationRiskResponse.NonActionableIncident.selector);
        response.handleIncident(incident);
    }

    function testTargetWithNoCodeRejected() public {
        address emptyTarget = address(0xBEEF);
        registry.setConfig(ENV, emptyTarget, address(response), true);
        TempleTypes.Incident memory incident = _sampleIncident(emptyTarget, ENV);
        vm.prank(DROSERA);
        vm.expectRevert(TempleMigrationRiskResponse.TargetHasNoCode.selector);
        response.handleIncident(incident);
    }

    function testPauseFailureReverts() public {
        FailingPauseTarget failing = new FailingPauseTarget(token);
        TempleMigrationBackingRegistry failingRegistry = new TempleMigrationBackingRegistry(ENV, address(failing), address(1), true);
        TempleMigrationRiskResponse failingResponse = new TempleMigrationRiskResponse(DROSERA, address(failingRegistry), address(0), 0);
        failingRegistry.setConfig(ENV, address(failing), address(failingResponse), true);
        TempleTypes.Incident memory incident = _sampleIncident(address(failing), ENV);
        vm.prank(DROSERA);
        vm.expectRevert();
        failingResponse.handleIncident(incident);
    }

    function testAlertSinkOnlyResponse() public {
        TempleTelegramAlertSink sink = new TempleTelegramAlertSink(address(response));
        TempleTypes.Incident memory incident = _sampleIncident(address(staking), ENV);
        vm.expectRevert(TempleTelegramAlertSink.OnlyResponse.selector);
        sink.notifyTempleIncident(incident);
    }

    function testFullTempleStylePath_FakeMigrationWithdrawAndSwap() public {
        MockERC20 lp = new MockERC20("Temple FRAX LP", "xLP");
        MockERC20 temple = new MockERC20("Temple", "TEMPLE");
        MockERC20 frax = new MockERC20("Frax", "FRAX");
        TempleStaxMigrationMockV2 stakingV2 = new TempleStaxMigrationMockV2(address(lp));
        MockTempleFraxPair pair = new MockTempleFraxPair(address(lp), address(temple), address(frax));

        lp.mint(address(this), 2_000 ether);
        lp.approve(address(stakingV2), 1_000 ether);
        stakingV2.seedBackedStake(address(0xC0FFEE), 1_000 ether);

        lp.approve(address(pair), 1_000 ether);
        pair.seedLiquidity(1_000 ether, 500_000 ether, 500_000 ether);

        TempleMigrationAttackerV2 attacker = new TempleMigrationAttackerV2(
            address(stakingV2),
            address(pair),
            address(lp),
            address(temple),
            address(frax)
        );

        stakingV2.setWhitelistEnforcement(false);
        attacker.stageFakeMigration(1_000 ether);

        TempleTypes.Metrics memory metrics = stakingV2.templeMigrationMetrics();
        _assertTrue(metrics.creditedStake > metrics.tokenBacking, "must be underbacked");
        _assertTrue(metrics.lastBackingAfter - metrics.lastBackingBefore < metrics.lastMigrationAmount, "migration lacks LP inflow");
        _assertFalse(metrics.oldStakingTrusted, "fake old staking is untrusted");

        attacker.withdrawLp();
        (uint256 lpBal,,) = attacker.balances();
        _assertTrue(lpBal > 0, "attacker must receive LP");

        attacker.swapLpToTempleFrax(lpBal);
        (, uint256 templeBal, uint256 fraxBal) = attacker.balances();
        _assertTrue(templeBal > 0 || fraxBal > 0, "attacker must swap into underlying");
    }

    function testFixedWhitelistBlocksFakeMigration() public {
        MockERC20 lp = new MockERC20("Temple FRAX LP", "xLP");
        TempleStaxMigrationMockV2 stakingV2 = new TempleStaxMigrationMockV2(address(lp));
        FakeOldStakingV2 fake = new FakeOldStakingV2();

        stakingV2.setWhitelistEnforcement(true);

        bool reverted;
        try stakingV2.migrateStake(address(fake), 1_000 ether) {}
        catch {
            reverted = true;
        }
        _assertTrue(reverted, "fake migration must revert when whitelist enforced");
    }

    function testTrustedOldStakingMigrationIsBacked() public {
        MockERC20 lp = new MockERC20("Temple FRAX LP", "xLP");
        TempleStaxMigrationMockV2 stakingV2 = new TempleStaxMigrationMockV2(address(lp));
        GoodOldStakingV2 good = new GoodOldStakingV2(address(lp));

        lp.mint(address(this), 1_000 ether);
        lp.approve(address(good), 1_000 ether);
        good.seed(ATTACKER, 1_000 ether);

        stakingV2.setTrustedOldStaking(address(good), true);
        stakingV2.setWhitelistEnforcement(true);

        vm.prank(ATTACKER);
        stakingV2.migrateStake(address(good), 1_000 ether);

        TempleTypes.Metrics memory metrics = stakingV2.templeMigrationMetrics();
        _assertTrue(metrics.oldStakingTrusted, "old staking should be trusted");
        _assertTrue(metrics.lastBackingAfter - metrics.lastBackingBefore == metrics.lastMigrationAmount, "trusted migration is backed");
    }

    function _handle(TempleMigrationBackingTrap trap) internal {
        bytes[] memory data = _collectWindow(trap);
        (bool ok, bytes memory payload) = trap.shouldRespond(data);
        _assertTrue(ok, "trap should fire");
        TempleTypes.Incident memory incident = abi.decode(payload, (TempleTypes.Incident));
        vm.prank(DROSERA);
        response.handleIncident(incident);
        _assertTrue(staking.paused(), "target paused");
    }

    function _stageFakeMigration() internal {
        FakeOldStaking fake = new FakeOldStaking();
        vm.prank(ATTACKER);
        staking.migrateStake(address(fake), 1_000 ether);
    }

    function _collectWindow(TempleMigrationBackingTrap trap) internal returns (bytes[] memory data) {
        data = new bytes[](3);
        data[2] = trap.collect();
        vm.roll(block.number + 1);
        data[1] = trap.collect();
        vm.roll(block.number + 1);
        data[0] = trap.collect();
    }

    function _sampleIncident(address target, bytes32 environmentId) internal pure returns (TempleTypes.Incident memory) {
        return TempleTypes.Incident({
            invariantId: TempleTypes.INVARIANT_ID,
            environmentId: environmentId,
            target: target,
            blockNumber: 101,
            creditedStake: 1_000 ether,
            tokenBacking: 0,
            lastMigrationOldStaking: address(0xBAD),
            lastMigrator: ATTACKER,
            lastMigrationAmount: 1_000 ether,
            lastBackingBefore: 0,
            lastBackingAfter: 0,
            reasonBitmap: TempleTypes.REASON_UNBACKED_STAKE | TempleTypes.REASON_UNTRUSTED_MIGRATOR,
            extraData: ""
        });
    }

    function _repeatSample(bytes memory sample) internal pure returns (bytes[] memory data) {
        data = new bytes[](3);
        data[0] = sample;
        data[1] = sample;
        data[2] = sample;
    }

    function _installRegistryForTrap(
        address registryCode,
        bytes32 environmentId,
        address target,
        address executor,
        bool active
    ) internal {
        vm.etch(REGISTRY_ADDR, registryCode.code);
        vm.store(REGISTRY_ADDR, bytes32(uint256(0)), bytes32(uint256(uint160(address(this)))));
        vm.store(REGISTRY_ADDR, bytes32(uint256(1)), bytes32(uint256(active ? 1 : 0)));
        vm.store(REGISTRY_ADDR, bytes32(uint256(2)), environmentId);
        vm.store(REGISTRY_ADDR, bytes32(uint256(3)), bytes32(uint256(uint160(target))));
        vm.store(REGISTRY_ADDR, bytes32(uint256(4)), bytes32(uint256(uint160(executor))));
    }

    function _assertTrue(bool value, string memory reason) internal pure {
        require(value, reason);
    }

    function _assertFalse(bool value, string memory reason) internal pure {
        require(!value, reason);
    }
}
