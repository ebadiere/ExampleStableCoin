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

contract Handler is Test {
    StableCoin public stableCoin;
    StableCoinEngine public engine;
    MockCollateralToken public collateral;
    ProxyAdmin public proxyAdmin;
    StableCoinProxy public stableCoinProxy;
    StableCoinProxy public engineProxy;

    address public owner = address(this);
    address public user1 = address(0x1);
    address public user2 = address(0x2);

    constructor() {
        // Deploy ProxyAdmin
        proxyAdmin = new ProxyAdmin();

        // Deploy mock collateral token
        collateral = new MockCollateralToken();
        collateral.initialize();
        deal(address(collateral), user1, 1000e18);

        // Deploy implementation contracts
        stableCoin = new StableCoin();
        engine = new StableCoinEngine();

        // Prepare initialization data
        bytes memory stableCoinData =
            abi.encodeWithSelector(StableCoin.initialize.selector, "StableCoin", "SC", address(engine));

        bytes memory engineData =
            abi.encodeWithSelector(StableCoinEngine.initialize.selector, address(collateral), address(stableCoin));

        // Deploy proxies
        stableCoinProxy = new StableCoinProxy(address(stableCoin), address(proxyAdmin), stableCoinData);

        engineProxy = new StableCoinProxy(address(engine), address(proxyAdmin), engineData);

        // Update references to use proxies
        stableCoin = StableCoin(address(stableCoinProxy));
        engine = StableCoinEngine(address(engineProxy));

        // Set initial price
        engine.updatePrice(1e8); // $1 per token
        vm.warp(block.timestamp + 1 hours);
        engine.updatePrice(1e8);
    }

    function deposit(uint256 amount) public {
        amount = bound(amount, 0, 1000e18);
        vm.startPrank(user1);
        collateral.approve(address(engine), amount);
        engine.deposit(amount);
        vm.stopPrank();
    }

    function withdraw(uint256 amount) public {
        amount = bound(amount, 0, 1000e18);
        vm.startPrank(user1);
        engine.withdraw(amount);
        vm.stopPrank();
    }

    function mint(uint256 amount) public {
        amount = bound(amount, 0, 1000e18);
        vm.startPrank(user1);
        engine.mint(amount);
        vm.stopPrank();
    }

    function burn(uint256 amount) public {
        amount = bound(amount, 0, 1000e18);
        vm.startPrank(user1);
        engine.burn(amount);
        vm.stopPrank();
    }

    function updatePrice(uint256 newPrice) public {
        newPrice = bound(newPrice, 0.5e8, 2e8);
        vm.warp(block.timestamp + 1 hours);
        engine.updatePrice(newPrice);
    }

    function liquidate() public {
        if (engine.isLiquidatable(user1)) {
            vm.startPrank(user2);
            (, uint256 debtAmount,,) = engine.positions(user1);
            if (debtAmount > 0) {
                deal(address(stableCoin), user2, debtAmount);
                stableCoin.approve(address(engine), debtAmount);
                engine.liquidate(user1);
            }
            vm.stopPrank();
        }
    }
}

contract StableCoinInvariantTest is Test {
    StableCoin stableCoin;
    StableCoinEngine engine;
    MockCollateralToken collateral;
    ProxyAdmin proxyAdmin;
    StableCoinProxy stableCoinProxy;
    StableCoinProxy engineProxy;

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

        // Deploy implementation contracts
        stableCoin = new StableCoin();
        engine = new StableCoinEngine();

        // Deploy proxies with empty initialization data
        engineProxy = new StableCoinProxy(
            address(engine),
            address(proxyAdmin),
            "" // Empty data, we'll initialize later
        );

        stableCoinProxy = new StableCoinProxy(
            address(stableCoin),
            address(proxyAdmin),
            "" // Empty data, we'll initialize later
        );

        // Initialize contracts in the correct order
        vm.startPrank(owner);

        StableCoin(address(stableCoinProxy)).initialize("StableCoin", "SC", address(engineProxy), owner);

        StableCoinEngine(address(engineProxy)).initialize(address(collateral), address(stableCoinProxy), owner);

        // Set initial price
        StableCoinEngine(address(engineProxy)).updatePrice(1000e18); // $1000 per token

        vm.stopPrank();

        // Update references to use proxies
        stableCoin = StableCoin(address(stableCoinProxy));
        engine = StableCoinEngine(address(engineProxy));
    }

    function invariant_totalSupplyMatchesTotalDebt() public {
        uint256 totalSupply = stableCoin.totalSupply();
        uint256 totalDebt = 0;
        address[] memory users = engine.getUsers();

        for (uint256 i = 0; i < users.length; i++) {
            (, uint256 debtAmount,,) = engine.positions(users[i]);
            totalDebt += debtAmount;
        }

        assertEq(totalSupply, totalDebt, "Total supply should equal total debt");
    }

    function invariant_collateralBalanceMatchesPositions() public {
        uint256 totalCollateral = 0;
        address[] memory users = engine.getUsers();

        for (uint256 i = 0; i < users.length; i++) {
            (uint256 collateralAmount,,,) = engine.positions(users[i]);
            totalCollateral += collateralAmount;
        }

        assertEq(
            collateral.balanceOf(address(engineProxy)),
            totalCollateral,
            "Engine collateral balance should match sum of positions"
        );
    }

    function invariant_healthFactorsAboveMinimum() public {
        address[] memory users = engine.getUsers();

        for (uint256 i = 0; i < users.length; i++) {
            (uint256 collateralAmount, uint256 debtAmount,,) = engine.positions(users[i]);
            if (debtAmount > 0) {
                // Check if position is liquidatable, which means health factor is below minimum
                assertFalse(engine.isLiquidatable(users[i]), "Health factor below minimum");
            }
        }
    }
}
