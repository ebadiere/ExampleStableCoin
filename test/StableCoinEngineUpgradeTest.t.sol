// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/StableCoin.sol";
import "../src/StableCoinEngine.sol";
import "../src/proxy/StableCoinProxy.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";

contract MockCollateralToken is ERC20Upgradeable {
    function initialize() external initializer {
        __ERC20_init("Mock Token", "MTK");
        _mint(msg.sender, 1_000_000e18);
    }
}

contract MockV2StableCoinEngine is StableCoinEngine {
    uint256 public constant VERSION = 2;

    function version() external pure returns (uint256) {
        return VERSION;
    }
}

contract StableCoinEngineUpgradeTest is Test {
    StableCoinEngine engineImpl;
    StableCoin stableCoin;
    StableCoinProxy engineProxy;
    MockCollateralToken collateral;
    ProxyAdmin proxyAdmin;

    address owner = address(0x123);
    address user1 = address(0x1);
    address user2 = address(0x2);

    function setUp() public {
        // Deploy ProxyAdmin
        proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(owner);

        // Deploy mock collateral token
        collateral = new MockCollateralToken();
        collateral.initialize();
        deal(address(collateral), user1, 1000e18);

        // Deploy implementation contracts
        engineImpl = new StableCoinEngine();
        stableCoin = new StableCoin();

        // Deploy proxies with empty initialization data
        engineProxy = new StableCoinProxy(
            address(engineImpl),
            address(proxyAdmin),
            "" // Empty data, we'll initialize later
        );

        StableCoinProxy stableCoinProxy = new StableCoinProxy(
            address(stableCoin),
            address(proxyAdmin),
            "" // Empty data, we'll initialize later
        );

        // Initialize contracts in the correct order
        vm.startPrank(owner);

        StableCoin(address(stableCoinProxy)).initialize("StableCoin", "SC", address(engineProxy), owner);

        StableCoinEngine(address(engineProxy)).initialize(address(collateral), address(stableCoinProxy), owner);

        // Update references to use proxies
        stableCoin = StableCoin(address(stableCoinProxy));
        engineImpl = StableCoinEngine(address(engineProxy));

        vm.stopPrank();
    }

    function test_InitialDeployment() public {
        assertEq(address(engineImpl.collateralToken()), address(collateral));
        assertEq(address(engineImpl.stableCoin()), address(stableCoin));
        assertEq(engineImpl.owner(), owner);
    }

    function test_UpgradeEngine() public {
        // Deploy new implementation
        MockV2StableCoinEngine newImpl = new MockV2StableCoinEngine();

        vm.prank(owner);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(engineProxy)), address(newImpl));

        // Check upgrade was successful
        assertEq(MockV2StableCoinEngine(address(engineProxy)).version(), 2);
        assertEq(StableCoinEngine(address(engineProxy)).owner(), owner);
    }

    function test_RevertOnDoubleInitialization() public {
        vm.expectRevert("Initializable: contract is already initialized");
        StableCoinEngine(address(engineProxy)).initialize(address(collateral), address(stableCoin), owner);
    }

    function test_StorageLayoutPreserved() public {
        // Set up initial state
        vm.startPrank(user1);
        collateral.approve(address(engineProxy), 1000e18);
        engineImpl.deposit(1000e18);
        vm.stopPrank();

        // Upgrade contract
        MockV2StableCoinEngine newImpl = new MockV2StableCoinEngine();
        vm.prank(owner);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(engineProxy)), address(newImpl));

        // Verify state is preserved
        assertEq(address(engineImpl.collateralToken()), address(collateral));
        assertEq(address(engineImpl.stableCoin()), address(stableCoin));
        assertEq(engineImpl.owner(), owner);
        (uint256 collateralAmount,,,) = engineImpl.positions(user1);
        assertEq(collateralAmount, 1000e18);
    }
}
