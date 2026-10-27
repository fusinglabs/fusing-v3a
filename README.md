# fusi.ng V3a

The first V3 stack (27 September 2026): one factory for single and multi-market launches, the Fuse Vault, launch modules and tokenised-stock quotes.

Solidity smart contracts of [fusi.ng](https://fusi.ng), a token launchpad on Ethereum built on Uniswap V4. Ethereum mainnet only.

- Website: https://fusi.ng
- Docs and ABIs: https://fusi.ng/docs#tech
- X: https://x.com/fusi_ng
- Telegram: https://t.me/fusi_ng

## Deployed contracts (Ethereum mainnet)

| Role | Address | Contract | Source status |
| --- | --- | --- | --- |
| autoLpModule | [`0x6F3B1DC5bD99D74EF69Bfbfa15a89f4f0B7ABE7c`](https://etherscan.io/address/0x6F3B1DC5bD99D74EF69Bfbfa15a89f4f0B7ABE7c) |  | same source family, not separately checked |
| burnModule | [`0x0642affF9b9f3d5B8a924D4a6bC153afB482c198`](https://etherscan.io/address/0x0642affF9b9f3d5B8a924D4a6bC153afB482c198) |  | same source family, not separately checked |
| factory | [`0xCB2917b10c0D0Ff6Bd2eD34271f00f356c6D5Ba8`](https://etherscan.io/address/0xCB2917b10c0D0Ff6Bd2eD34271f00f356c6D5Ba8) |  | NOT matched, see note |
| feeConverter | [`0xD5eE69485cBFcC294f13Ca98D1aceaA5e53FF6B6`](https://etherscan.io/address/0xD5eE69485cBFcC294f13Ca98D1aceaA5e53FF6B6) |  | same source family, not separately checked |
| feeEscrow | [`0x58BF4846D583f10b4aC62edC35Fd8F5a931d2B74`](https://etherscan.io/address/0x58BF4846D583f10b4aC62edC35Fd8F5a931d2B74) |  | bytecode identical to the verified V3b contract |
| feeHook | [`0x834DEB445D44244ad1268F0149C7dfBBF9d5e0c0`](https://etherscan.io/address/0x834DEB445D44244ad1268F0149C7dfBBF9d5e0c0) |  | bytecode matches this source |
| fuseVault | [`0xED630B4A74c8D655C2c7e48dE1BCC185E5f08F79`](https://etherscan.io/address/0xED630B4A74c8D655C2c7e48dE1BCC185E5f08F79) |  | bytecode matches this source |
| handlesModule | [`0x441afae87aE0a95D378c8c87897e0f4aDBa35ec0`](https://etherscan.io/address/0x441afae87aE0a95D378c8c87897e0f4aDBa35ec0) |  | same source family, not separately checked |
| launchDeployer | [`0xFF9A57ca1bA124EDc68B829129434A1F77748F7c`](https://etherscan.io/address/0xFF9A57ca1bA124EDc68B829129434A1F77748F7c) |  | bytecode matches this source |
| leanDeployer | [`0x06ef5a5dF3bE94CD41Fe627Fe69dD419247f31B2`](https://etherscan.io/address/0x06ef5a5dF3bE94CD41Fe627Fe69dD419247f31B2) |  | bytecode matches this source |
| locker | [`0x6fADf16e8C462b372CAdC2d483eF0799096b2435`](https://etherscan.io/address/0x6fADf16e8C462b372CAdC2d483eF0799096b2435) |  | bytecode matches this source |
| positionMinter | [`0x8Da28083Db225D4CbEBd9aA0d26BE909770e9673`](https://etherscan.io/address/0x8Da28083Db225D4CbEBd9aA0d26BE909770e9673) |  | same source family, not separately checked |
| quotePricer | [`0xB9A5B38bC51a5D2192bb609a39250f2d60e9F87C`](https://etherscan.io/address/0xB9A5B38bC51a5D2192bb609a39250f2d60e9F87C) |  | bytecode identical to the verified V3b contract |
| referenceRegistry | [`0x766290aad4B0a98680397a5FFA33e3cC8a5D1951`](https://etherscan.io/address/0x766290aad4B0a98680397a5FFA33e3cC8a5D1951) |  | same source family, not separately checked |
| router | [`0x74F5e8fdFe77120Ff8254c4CE234105973D7709f`](https://etherscan.io/address/0x74F5e8fdFe77120Ff8254c4CE234105973D7709f) |  | NOT matched, see note |
| stockDesk | [`0x39D3FcE84EB748253b538487026883FE662804d1`](https://etherscan.io/address/0x39D3FcE84EB748253b538487026883FE662804d1) |  | same source family, not separately checked |
| tokenLock | [`0x78E6dB4047f04892959F40808a16592842958CBA`](https://etherscan.io/address/0x78E6dB4047f04892959F40808a16592842958CBA) |  | bytecode identical to the verified V3b contract |
| walletsModule | [`0x2d4aFa087988E8f03f312c8Be63eCE50158847D2`](https://etherscan.io/address/0x2d4aFa087988E8f03f312c8Be63eCE50158847D2) |  | bytecode matches this source |

## Source note

This is the V3 source tree as it stood when V3a was live, recovered from the build that matches the chain. Each contract was checked by comparing its compiled runtime bytecode with the deployed code (immutables masked). The factory and router were changed again before this snapshot was taken, so for those two contracts this source is close to, but not exactly, what is deployed. The V3b repository holds the exact, Etherscan-verified source of the next stack.

Compiler: solc 0.8.26. Exact compiler settings are in each verified contract on Etherscan.

## License

MIT, as declared in each file's SPDX header.
