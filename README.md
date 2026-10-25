# Runner (RUNNER)

Runner is an immutable ERC-20 token. Its constructor mints exactly
**1,000,000,000 RUNNER**, with **18 decimals**, to the immediate deploying address.
The supply in base units is **1000000000000000000000000000** (`10^27`).

## Contract and assumptions

- Production contract: `src/Runner.sol:Runner`.
- `INITIAL_SUPPLY` is the named constant for the full lifetime supply.
- Name and symbol are fixed as `Runner` and `RUNNER`.
- Transfers deliver the exact requested amount. There are no taxes, rebases,
  restrictions by address, or transfer callbacks.
- There is no owner, administrator, minter, pause, blacklist, burn, seizure,
  initialization, or upgrade entry point. The only mint occurs in the constructor.
- A factory deployment gives the full supply to that factory (`msg.sender`), not
  the account that called the factory. Distribution is the factory's responsibility.
- Standard ERC-20 behavior is used where the brief does not add requirements:
  zero-value transfers and self-transfers succeed; transfers to the zero address
  and approvals to the zero spender revert. Insufficient balances or allowances
  revert without changing balances or allowances.
- `approve` replaces an existing allowance. An allowance of `type(uint256).max`
  is unlimited and is not reduced by `transferFrom`. Finite allowances decrease
  on use, including when the transfer recipient is the source account. As in
  OpenZeppelin v5, spending allowance emits `Transfer`, but not another `Approval`.

The implementation inherits the unmodified OpenZeppelin Contracts **v5.4.0**
ERC-20 implementation. The required dependency files and their license are in
`lib/openzeppelin-contracts`. Foundry tests use vendored forge-std **v1.9.7**.
Source archive URLs and SHA-256 hashes are recorded in `lib/PROVENANCE.txt`.
Dependencies are ordinary files; no submodules or package installation are needed.

## Build and check

Use Foundry with Solidity **0.8.26** installed. `foundry.toml` pins that version,
targets Cancun, enables the optimizer with 200 runs, and sets
`bytecode_hash = "none"` for reproducible launch bytecode. The build requires no
RPC, wallet, external services, FFI, or filesystem cheatcode permissions. Once
the pinned compiler is installed, dependencies resolve entirely from this tree.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x77c8e366c454b6316464fd82672bfef802e5f8c8db39c793183469fb95052790 forge test
forge fmt --check
```

The suite covers metadata and exact initial supply, the single mint event, direct
and CREATE2 factory deployment, exact distribution and claim transfers, events,
approvals and revocation, finite and unlimited spending, zero and self transfers,
insufficient balance/allowance, rollback after failure, rejected admin selectors,
and rejected native currency payments. Fuzz tests use 1,024 cases per test.
Stateful testing is configured for 128 sequences of 64 operations against a
separate balance and allowance model, checking supply conservation and spending.
Tests do not read or modify environment variables or require a fork.

Local validation passed `forge build`, `forge fmt --check`, and `forge test` with
the seed above: 30 unit/fuzz tests and both stateful invariants (8,192 handler
calls, zero reverts). The compiled artifact was also checked for its constructor
and public ABI, unresolved library links, runtime size, and the protected
test's prohibited-opcode rule. Slither and Mythril were not run.

The local factory test checks token accounting with test recipients; it does not
simulate Uniswap pricing or execute real swaps. The platform's protected launch
tests require its separate factory/pool harness, launch manifest, and runtime
configuration. Those are not part of this project.

## Deployment parameters

| Field | Value |
| --- | --- |
| Solidity identifier | `Runner` |
| Artifact | `out/Runner.sol/Runner.json` |
| Constructor arguments | None (`[]`) |
| Native currency value | `0` |
| Token name / symbol | `Runner` / `RUNNER` |
| Decimals | `18` |
| Total supply (base units) | `1000000000000000000000000000` |
| Initial recipient | The immediate deployer (`msg.sender`) |
| Intended launch network | Ethereum, chain ID `1` |
| Linked libraries / application contracts | None |
| Initialization / post-deployment settings | None |

Build the creation bytecode using the checked-in compiler settings:

```sh
forge inspect src/Runner.sol:Runner bytecode
forge inspect src/Runner.sol:Runner abi
```

Deploy that creation bytecode without appended constructor arguments and with
zero native currency value. The authorized launch factory must be the immediate
deployer for the launch factory to receive the supply. No chain-specific address
is embedded in Runner. The separate launch process produces `launch.json`,
deploys the token, and handles pool creation and distribution. No deployment or
broadcast is performed by this repository's tests.

The supplied launch economics are external to the token: 10% goes to the launch
distributor, 80% seeds the pool, and the remaining 10% goes to
`0x612a9bb008e16ef2d24f41dae9fc661831d93367`. The supplied paired currency is IMD
at `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, with 18 decimals. The supplied
pool fee is `12500` (1.25%), tick spacing is `60`, and initial market cap is
`5000000000000000000000` in paired currency base units. These are launch inputs,
not token configuration or values verified through an RPC by this project.

## After launch

There are no owner-only settings or maintenance transactions. The launch operator
is responsible for verifying the deployed source and compiler settings, confirming
the metadata and supply, and completing and checking distribution and liquidity
setup. Independent adversarial review and the platform's launch integration checks
remain release responsibilities; unit and invariant tests are not a security audit.

Holders control transfers and approvals. Applications should request only the
allowance they need. When replacing an existing nonzero allowance, holders should
consider revoking it first and confirming that transaction before granting a new
amount; a spender may use an existing allowance before a pending update is mined.

There is no recovery or rescue function. Transfers to the token contract or to
other contracts that cannot send ERC-20s can strand tokens permanently. Direct ETH
payments revert; forcibly delivered ETH cannot be recovered. Wallet security,
recipient verification, and allowance management remain the holders'
responsibility. The contract makes no oracle or external contract calls and has
no scheduled jobs or operational accounts.
