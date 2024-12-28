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
        _mint(msg.sender, 1000000e18);
    }
}

contract MockV2StableCoin is StableCoin {
    uint256 public constant VERSION = 2;

    function version() external pure returns (uint256) {
        return VERSION;
    }
}

contract MockV2StableCoinEngine is StableCoinEngine {
    uint256 public constant VERSION = 2;

    function version() external pure returns (uint256) {
        return VERSION;
    }
}

contract StableCoinUpgradeTest is Test {
    StableCoin stableCoinImpl;
    StableCoinEngine engineImpl;
    StableCoinProxy stableCoinProxy;
    StableCoinProxy engineProxy;
    MockCollateralToken collateralToken;
    ProxyAdmin proxyAdmin;

    address owner = address(0x123);
    address user1 = address(0x1);
    address user2 = address(0x2);

    function setUp() public {
        // Deploy ProxyAdmin
        proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(owner);

        // Deploy mock collateral token
        collateralToken = new MockCollateralToken();
        collateralToken.initialize();

        // Deploy implementation contracts
        stableCoinImpl = new StableCoin();
        engineImpl = new StableCoinEngine();

        // Deploy proxies with empty initialization data
        engineProxy = new StableCoinProxy(
            address(engineImpl),
            address(proxyAdmin),
            "" // Empty data, we'll initialize later
        );

        stableCoinProxy = new StableCoinProxy(
            address(stableCoinImpl),
            address(proxyAdmin),
            "" // Empty data, we'll initialize later
        );

        // Initialize contracts in the correct order
        vm.startPrank(owner);
        
        StableCoin(address(stableCoinProxy)).initialize(
            "StableCoin",
            "SC",
            address(engineProxy),
            owner
        );

        StableCoinEngine(address(engineProxy)).initialize(
            address(collateralToken),
            address(stableCoinProxy),
            owner
        );

        vm.stopPrank();
    }

    function test_InitialDeployment() public {
        assertEq(StableCoin(address(stableCoinProxy)).name(), "StableCoin");
        assertEq(StableCoin(address(stableCoinProxy)).symbol(), "SC");
        assertEq(StableCoin(address(stableCoinProxy)).engine(), address(engineProxy));
        assertEq(StableCoin(address(stableCoinProxy)).owner(), owner);
    }

    function test_OnlyAdminCanUpgrade() public {
        MockV2StableCoin newImpl = new MockV2StableCoin();
        
        // Try to upgrade from non-admin account
        vm.prank(user1);
        vm.expectRevert();
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(stableCoinProxy)), address(newImpl));
        
        // Upgrade from admin account should succeed
        vm.prank(owner);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(stableCoinProxy)), address(newImpl));
        
        assertEq(MockV2StableCoin(address(stableCoinProxy)).version(), 2);
    }

    function test_StorageLayoutPreserved() public {
        // Set up initial state
        vm.prank(address(engineProxy));
        StableCoin(address(stableCoinProxy)).mint(user1, 1000e18);
        
        // Upgrade contract
        MockV2StableCoin newImpl = new MockV2StableCoin();
        vm.prank(owner);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(stableCoinProxy)), address(newImpl));
        
        // Verify state is preserved
        assertEq(StableCoin(address(stableCoinProxy)).balanceOf(user1), 1000e18);
        assertEq(StableCoin(address(stableCoinProxy)).owner(), owner);
    }

    function test_UpgradeDoesNotAffectProxyAddress() public {
        address originalProxyAddress = address(stableCoinProxy);
        
        // Upgrade to v2
        MockV2StableCoin newImpl = new MockV2StableCoin();
        vm.prank(owner);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(stableCoinProxy)), address(newImpl));
        
        // Check proxy address remains the same
        assertEq(address(stableCoinProxy), originalProxyAddress);
    }

    function test_UpgradeStableCoin() public {
        // Deploy new implementation
        MockV2StableCoin newImpl = new MockV2StableCoin();
        
        vm.prank(owner);
        proxyAdmin.upgrade(ITransparentUpgradeableProxy(address(stableCoinProxy)), address(newImpl));
        
        // Check upgrade was successful
        assertEq(MockV2StableCoin(address(stableCoinProxy)).version(), 2);
        
        // Verify original data is preserved
        assertEq(StableCoin(address(stableCoinProxy)).name(), "StableCoin");
        assertEq(StableCoin(address(stableCoinProxy)).symbol(), "SC");
        assertEq(StableCoin(address(stableCoinProxy)).owner(), owner);
    }

    function test_UpgradeStableCoinEngine() public {
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
        StableCoin(address(stableCoinProxy)).initialize(
            "StableCoin",
            "SC",
            address(engineProxy),
            owner
        );
    }
}
