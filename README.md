# Bananapus Buyback Hook

When a Juicebox project that uses the buyback hook is paid, it checks whether buying tokens in a Uniswap pool or paying the project as usual would yield more tokens for the payer. If buying tokens in the pool would yield more tokens, the payment is routed there. Otherwise, the payment is sent to the project as usual. Either way, the project's reserved rate applies.

The buyback hook works with any Juicebox terminal and checks the Uniswap pool specified by the project's owner.

_If you're having trouble understanding this contract, take a look at the [core protocol contracts](https://github.com/Bananapus/nana-core) and the [documentation](https://docs.juicebox.money/) first. If you have questions, reach out on [Discord](https://discord.com/invite/ErQYmth4dS)._

## Install

For `npm` projects (recommended):

```bash
npm install @bananapus/buyback-hook
```

For `forge` projects (not recommended):

```bash
forge install Bananapus/nana-buyback-hook
```

Add `@bananapus/buyback-hook/=lib/nana-buyback-hook/` to `remappings.txt`. You'll also need to install `nana-buyback-hook`'s dependencies and add similar remappings for them.

## Develop

`nana-buyback-hook` uses the [Foundry](https://github.com/foundry-rs/foundry) development toolchain for builds, tests, and deployments. To get set up, install [Foundry](https://github.com/foundry-rs/foundry):

```bash
curl -L https://foundry.paradigm.xyz | sh
```

You can download and install dependencies with:

```bash
forge install
```

If you run into trouble with `forge install`, try using `git submodule update --init --recursive` to ensure that nested submodules have been properly initialized.

Some useful commands:

| Command               | Description                                         |
| --------------------- | --------------------------------------------------- |
| `forge build`         | Compile the contracts and write artifacts to `out`. |
| `forge fmt`           | Lint.                                               |
| `forge test`          | Run the tests.                                      |
| `forge build --sizes` | Get contract sizes.                                 |
| `forge coverage`      | Generate a test coverage report.                    |
| `foundryup`           | Update foundry. Run this periodically.              |
| `forge clean`         | Remove the build artifacts and cache directories.   |

To learn more, visit the [Foundry Book](https://book.getfoundry.sh/) docs.

## Scripts

For convenience, several utility commands are available in `package.json`.

| Command                           | Description                            |
| --------------------------------- | -------------------------------------- |
| `npm test`                        | Run local tests.                       |
| `npm run test:fork`               | Run fork tests (for use in CI).        |
| `npm run coverage:lcov`           | Generate an LCOV test coverage report. |
| `npm run deploy:ethereum-mainnet` | Deploy to Ethereum mainnet             |
| `npm run deploy:ethereum-sepolia` | Deploy to Ethereum Sepolia testnet     |
| `npm run deploy:optimism-mainnet` | Deploy to Optimism mainnet             |
| `npm run deploy:optimism-testnet` | Deploy to Optimism testnet             |

## Hooks

This contract is both a _data hook_ and a _pay hook_. Data hooks receive information about a payment and put together a payload for the pay hook to execute.

Juicebox projects can specify a data hook in their `JBRulesetMetadata`. When someone attempts to pay or redeem from the project, the project's terminal records the payment in the terminal store, passing information about the payment to the data hook in the process. The data hook responds with a list of payloads – each payload specifies the address of a pay hook, as well as some custom data and an amount of funds to send to that pay hook.

Each pay hook can then execute custom behavior based on the custom data (and funds) they receive.

## Flow

1. The frontend client sends the hook a Uniswap quote, the amount of funds to use for the swap, and the minimum number of project tokens to receive in exchange from the Uniswap pool (accounting for slippage). These should be encoded using the [delegate metadata library](https://github.com/jbx-protocol/juice-delegate-metadata-lib). If no quote is provided, the hook uses a [time-weighted average price](https://blog.uniswap.org/uniswap-v3-oracles#what-is-twap).
2. The terminal's `pay(...)` function calls this buyback hook (as a data hook) to determine whether the swap should be executed or not. It makes this determination by considering the information that was passed in, information about the pool, and the project's current rules.
3. The buyback contract sends its determination back to the terminal. If it approved the swap, the terminal then calls the buyback hook's `afterPayRecordedWith(...)` method, which will wrap the ETH (to wETH), execute the swap, burns the token it received, and mints them again (it also mints tokens for any funds which weren't used in the swap, if any). This burning/re-minting process allows the buyback hook to apply the reserved rate and respect the caller's `preferClaimedTokens` preference.
4. If the swap failed (due to exceeding the maximum slippage, low liquidity, or something else) the delegate will mint tokens for the recipient according to the project's rules, and use `addToBalanceOf` to send the funds to the project.

## Usage

Tips for project owners using the buyback hook.

### Avoiding MEV

Every time the buyback hook chooses the swap route, a Uniswap trade will be executed, making payers vulnerable to MEV attacks.

To mitigate MEV attacks, frontend clients should provide a reasonable minimum quote, and the TWAP parameters should be carefully set – these parameters are used to calculate a default minimum quote when the payer/client doesn't provide one.

You can also avoid MEV attacks by using the Flashbots Protect RPC for transactions which trigger the buyback hook. You can add this RPC to your wallet on [protect.flashbots.net](https://protect.flashbots.net/). If you're using a multisig wallet (like a Gnosis Safe), make sure that the last signer signs and executes at the same time _while using the Flashbots Protect RPC._ For more information on mitigating MEV from your Gnosis Safe, see [this article](https://medium.com/gnosis-pm/gnosis-safe-mev-how-to-mitigate-it-347e13535e34).

### Setting TWAP Parameters

As the project owner, you have two parameters at your disposal to protect payers: the TWAP window and the maximum slippage tolerance. _See [TWAP Basics](#twap-basics) for an explanation._

#### Limitations

- Custom quotes provided by payers or the frontend override these settings.
- Low liquidity pools are vulnerable to TWAP manipulation by attackers.

#### Best Practices

- A shorter TWAP window gives more accurate data, but is easier to manipulate, while a longer TWAP window gives more stable data, but can grow inaccurate when volatility is high.
- A 30m TWAP window is a good starting point for high-activity pairs. If your token has less activity, consider a longer TWAP window, but be careful – if it's too high, your TWAP will give inaccurate quotes when volatility is high.
- A low slippage tolerance leaves less room for arbitrage, but may cause payments to go to the project instead of the pool, while a high slippage tolerance means more transactions will swap successfully, but they may be more susceptible to arbitrage.
- A 5% slippage tolerance is a good starting point for more volatile pairs. More mature trading pairs may go as low to 1-2%. If your project's issuance rate is far below the market price, consider a wider slippage tolerance to ensure payments are sent to the pool.

You'll also want to keep the pool's _cardinality_ in mind. This is the number of recent transactions the Uniswap pool keeps track of for calculating the TWAP. If the cardinality is only 1 (the default), then the TWAP will only take the most recent trade into account for calculations. Anyone can increase the pool's cardinality by calling the pool's `increaseObservationCardinalityNext(...)` function.

#### Further Reading

For an overview of TWAP risks, see [this article](https://medium.com/@chinmayf/so-you-want-to-use-twap-1f992f9d3819). Some other helpful resources:

- [Manipulating Uniswap v3 TWAP Oracles](https://github.com/euler-xyz/uni-v3-twap-manipulation/blob/master/cost-of-attack.pdf)
- [Uniswap Oracle Attack Simulator](https://www.euler.finance/blog/oracle-attack-simulator)
- [Euler's Oracle Risk Grading System & Oracle Attacks Tutorial](https://www.youtube.com/watch?v=snwUwj3QQ7M)

### Setting The Pool

- If you're using ETH (or another native token) in your pair, use the address from [`JBConstants.NATIVE_TOKEN`](https://github.com/Bananapus/juice-contracts-v4/blob/main/src/libraries/JBConstants.sol): `0x000000000000000000000000000000000000EEEe`.
- The `fee` is a `uint24` with the same representation as in Uniswap's contracts (basis points with 2 decimals): a 0.01% fee is `100`, a 0.05% fee is `500`, a 0.3% fee is `3000`, and a 1% fee is `10000`.

## TWAP Basics

When you trade tokens on Uniswap, you must provide a minimum acceptable price for your trade to protect against excessive price movement (also called "slippage"). If the price moves unfavourably beyond this slippage tolerance, your trade will not be executed, protecting you from receiving a worse deal than you were expecting.

The buyback hook allows payers (or frontend clients) to provide a minimum acceptable return from their trade, and the hook will only execute the trade if it can provide that return – if it _can't_, the terminal's default behavior takes over. In most cases, this means the payment will go to the project that the hook is associated with.

But if the payer (or frontend client) does not provide a minimum acceptable return, the buyback hook must calculate a fair minimum on its own. On Uniswap, the current price is called a "spot price". This can be dangerous to rely on, because the price can move around quickly. To solve this problem, Uniswap v3 exposes a smoothed-out price called a TWAP, or a time-weighted average price. This is calculated by taking the geometric mean of the price over a window of time, which you can learn more about [here](https://blog.uniswap.org/uniswap-v3-oracles#what-is-twap).

The buyback hook allows each project to specify a time window (period of time) over which to calculate the TWAP. It also allows each project to specify a "TWAP slippage tolerance". This is the same as the minimum acceptable price above: with a 5% TWAP slippage tolerance, the transaction will revert to the terminal's default behavior if the expected return is more than 5% worse than the TWAP price over the window.

## Risks

- This hook has only been used with terminals that accept ETH so far. It _should_ support any ERC-20 terminal, but has not been used for this in production.
- This hook depends on liquidity in a Uniswap v3 pool. If liquidity providers migrate to a new pool, the project's owner has to call `setPoolFor(...)`. If they migrate to a new exchange, this hook won't work.
- If there isn't enough liquidity, or if the max slippage isn't set properly, payers may receive fewer tokens than expected.
