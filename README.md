# Example Stablecoin Project

A decentralized stablecoin implementation that uses over-collateralization and liquidation mechanisms to maintain price stability. This project demonstrates core concepts of DeFi stablecoin systems including collateral management, price feeds, liquidations, and risk parameters.

## Key Features

- **Over-collateralization**: Users must provide more collateral value than the stablecoins they mint
- **Price Oracle**: Uses a Time-Weighted Average Price (TWAP) mechanism for reliable price feeds
- **Liquidation System**: Automatically liquidates unsafe positions to maintain system solvency
- **Risk Parameters**: Configurable parameters for collateral ratio, liquidation thresholds, and price feed staleness
- **ERC20 Compliant**: Both the stablecoin and collateral tokens follow the ERC20 standard

## Core Components

### StableCoin.sol
- ERC20-compliant stablecoin token
- Controlled minting and burning by the StableCoinEngine
- Role-based access control for secure operation

### StableCoinEngine.sol
- Manages collateral deposits and stablecoin minting
- Implements TWAP oracle for price feeds
- Handles liquidations of unsafe positions
- Enforces system risk parameters

## Key Parameters

- **Minimum Collateral Ratio**: 150%
- **Liquidation Threshold**: 120%
- **Liquidation Bonus**: 10%
- **Maximum Price Change**: 10% between updates
- **Price Update Frequency**: Minimum 5 minutes between updates
- **Price Staleness**: Data considered stale after 1 hour

## Development

This project uses the Foundry development framework.

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Building

```shell
$ forge build
```

### Testing

```shell
$ forge test
```

The test suite includes comprehensive tests for:
- Collateral management
- Price feed mechanics
- Liquidation scenarios
- Edge cases and error conditions

### Formatting

```shell
$ forge fmt
```

## Security Considerations

- Price feed manipulation protection through TWAP
- Minimum delay between price updates
- Maximum price change limits
- Collateral ratio safety margins
- Liquidation incentives for system stability

## License

This project is licensed under MIT.

---

## Foundry

This project uses [Foundry](https://book.getfoundry.sh/), a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.

### Foundry Components

- **Forge**: Ethereum testing framework
- **Cast**: Swiss army knife for interacting with EVM smart contracts
- **Anvil**: Local Ethereum node
- **Chisel**: Solidity REPL

For detailed Foundry documentation, visit https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```