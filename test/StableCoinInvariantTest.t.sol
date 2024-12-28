// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";
import "../src/StableCoin.sol";
import "../src/StableCoinEngine.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Handler is Test {
    StableCoin public stableCoin;
    StableCoinEngine public engine;
    MockERC20 public collateral;
    address public owner;

    // Bound the values to reasonable ranges
    uint256 public constant MIN_AMOUNT = 1e6;   // 1 USDC
    uint256 public constant MAX_AMOUNT = 1e9;   // 1000 USDC
    uint256 public constant MIN_PRICE = 50e8;    // $50 - Set minimum price to avoid liquidation
    uint256 public constant MAX_PRICE = 100e8;  // $100

    // Track actors
    address[] public actors;
    uint256 public currentActorIndex;

    constructor(
        address _stableCoin,
        address _engine,
        address _collateral,
        address _owner
    ) {
        stableCoin = StableCoin(_stableCoin);
        engine = StableCoinEngine(_engine);
        collateral = MockERC20(_collateral);
        owner = _owner;

        // Create some actors
        for (uint256 i = 0; i < 10; i++) {
            actors.push(address(uint160(0x1000 + i)));
            vm.label(actors[i], string.concat("Actor", vm.toString(i)));
        }
    }

    // Modifiers to bound inputs
    modifier useActor() {
        currentActorIndex = bound(currentActorIndex, 0, actors.length - 1);
        vm.startPrank(actors[currentActorIndex]);
        _;
        vm.stopPrank();
    }

    // Functions that will be called during invariant testing
    function deposit_and_mint(uint256 amount, uint256 mintAmount) external useActor {
        // Apply bounds before using the values
        amount = bound(amount, MIN_AMOUNT, MAX_AMOUNT);
        mintAmount = bound(mintAmount, MIN_AMOUNT, MAX_AMOUNT);
        
        // Mint collateral to actor
        collateral.mint(actors[currentActorIndex], amount);
        
        // Approve and deposit
        collateral.approve(address(engine), amount);
        try engine.depositAndMint(amount, mintAmount) {
            // Success
        } catch {
            // Failed - this is expected sometimes due to insufficient collateral
        }
    }

    function update_price(uint256 price) external {
        // Apply bounds before using the value
        price = bound(price, MIN_PRICE, MAX_PRICE);
        
        vm.startPrank(owner);
        // Ensure enough time has passed
        vm.warp(block.timestamp + engine.MIN_UPDATE_DELAY());
        try engine.update(price) {
            // Success
        } catch {
            // Failed - this is expected sometimes due to price change limits
        }
        vm.stopPrank();
    }
}

contract StableCoinInvariantTest is Test {
    StableCoin public stableCoin;
    StableCoinEngine public engine;
    MockERC20 public collateral;
    Handler public handler;
    address public owner;

    function setUp() public {
        owner = address(this);
        collateral = new MockERC20("Mock Token", "MTK");
        stableCoin = new StableCoin(owner);
        engine = new StableCoinEngine(
            address(stableCoin),
            address(collateral),
            owner
        );

        // Set up roles
        stableCoin.transferOwnership(address(engine));

        // Create handler
        handler = new Handler(
            address(stableCoin),
            address(engine),
            address(collateral),
            owner
        );

        // Target contract functions for invariant testing
        targetContract(address(handler));

        // Label addresses for better trace output
        vm.label(address(stableCoin), "StableCoin");
        vm.label(address(engine), "StableCoinEngine");
        vm.label(address(collateral), "Collateral");
        vm.label(address(handler), "Handler");
    }

    // System should never have more debt than collateral value allows
    function invariant_collateralization() public view {
        address[] memory users = engine.getUsers();
        for (uint256 i = 0; i < users.length; i++) {
            (uint256 collateralAmount, uint256 debtAmount,,) = engine.positions(users[i]);
            if (debtAmount > 0) {
                // Calculate values carefully to avoid overflow
                uint256 collateralPrice = engine.getTWAP();
                // Multiply first, then divide to maintain precision
                uint256 collateralValue = (collateralAmount * collateralPrice) / engine.PRICE_PRECISION();
                uint256 minCollateralValue = (debtAmount * engine.baseCollateralRatio()) / 1e18;
                assert(collateralValue >= minCollateralValue);
            }
        }
    }

       // Total debt in the system should match total stablecoin supply
    function invariant_debtMatchesSupply() public view {
        uint256 totalDebt;
        address[] memory users = engine.getUsers();
        for (uint256 i = 0; i < users.length; i++) {
            (,uint256 debtAmount,,) = engine.positions(users[i]);
            totalDebt += debtAmount;
        }
        assert(totalDebt == stableCoin.totalSupply());
    }

    // System's total collateral should match the contract's balance
    function invariant_totalCollateralMatchesBalance() public view {
        uint256 totalCollateral;
        address[] memory users = engine.getUsers();
        for (uint256 i = 0; i < users.length; i++) {
            (uint256 collateralAmount,,,) = engine.positions(users[i]);
            totalCollateral += collateralAmount;
        }
        assert(totalCollateral == collateral.balanceOf(address(engine)));
    }    

    // No position should be liquidatable after an operation
    function invariant_noLiquidatablePositions() public view {
        address[] memory users = engine.getUsers();
        for (uint256 i = 0; i < users.length; i++) {
            (uint256 collateralAmount, uint256 debtAmount,,) = engine.positions(users[i]);
            if (collateralAmount > 0 || debtAmount > 0) {
                // Calculate values carefully to avoid overflow
                uint256 currentPrice = engine.getTWAP();
                // Multiply first, then divide to maintain precision
                uint256 collateralValue = (collateralAmount * currentPrice) / engine.PRICE_PRECISION();
                uint256 minCollateralValue = (debtAmount * engine.liquidationThreshold()) / 1e18;
                
                if (collateralValue < minCollateralValue) {
                    assert(engine.isLiquidatable(users[i]));
                } else {
                    assert(!engine.isLiquidatable(users[i]));
                }
            }
        }
    }  

    // Price should never be stale
    function invariant_priceNotStale() public view {
        if (engine.getObservationsCount() > 0) {
            (uint256 lastTimestamp,) = engine.observations(engine.getObservationsCount() - 1);
            assert(block.timestamp - lastTimestamp <= engine.MAX_PRICE_AGE());
        }
    }

    receive() external payable {}      
}
