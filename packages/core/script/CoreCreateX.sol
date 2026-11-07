// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 Gully Labs (Gully Core)
pragma solidity ^0.8.24;

/// @notice The subset of CreateX (github.com/pcaversaccio/createx, AGPL-3.0) that core, periphery and
/// router release scripts use. Only the interface is declared here. No CreateX code is copied.
interface ICoreCreateX {
    struct Values {
        uint256 constructorAmount;
        uint256 initCallAmount;
    }

    function deployCreate2(bytes32 salt, bytes memory initCode) external payable returns (address newContract);

    function deployCreate2AndInit(
        bytes32 salt,
        bytes memory initCode,
        bytes memory data,
        Values memory values,
        address refundAddress
    ) external payable returns (address newContract);
}

/// @title CoreCreateX
/// @notice Deterministic deploys for the core / periphery / router release scripts through canonical CreateX
/// (Gully Core H-1, 2026-10-28). This replaces pancakeswap/pancake-create3-factory, which has no licence.
///
/// CREATE2, not CREATE3: these contracts set `owner = msg.sender` in their constructor. Under CreateX's
/// CREATE2 the constructor's `msg.sender` is CreateX itself, and `deployCreate2AndInit` makes the
/// ownership hand-over call FROM CreateX in the same call, so no window exists in which anyone else
/// owns the contract. (Under CREATE3 the owner would be CreateX's throwaway proxy, and ownership would
/// be unrecoverable.)
///
/// Salts are PERMISSIONED and chain-agnostic: `<deployer> ++ 0x00 ++ bytes11(label hash)`. Only the
/// deployer can use them, and CreateX guards them as `keccak256(abi.encode(bytes32(deployer), salt))`.
/// @dev The cheatcode used by `CoreCreateX.createX`.
interface ICoreCreateXEnv {
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function envOr(string calldata name, bytes32 defaultValue) external view returns (bytes32);
}

library CoreCreateX {
    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;
    /// @dev The cheatcode address, for the one environment read below.
    ICoreCreateXEnv private constant VM = ICoreCreateXEnv(address(uint160(uint256(keccak256("hevm cheat code")))));
    /// @dev Runtime code hash of canonical CreateX (identical on every chain; read on Gully Chain 485590).
    bytes32 internal constant CREATEX_RUNTIME_HASH = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;

    /// @notice CreateX on this chain: the canonical address, or `GULLYCORE_CREATEX` on a chain that cannot have it
    /// (Anubis: unmodified CreateX deployed through the Safe singleton factory). The runtime hash check in
    /// `deploy` is the same either way, so only unmodified CreateX code passes.
    function createX() internal view returns (address) {
        return VM.envOr("GULLYCORE_CREATEX", CREATEX);
    }

    function salt(address deployer, bytes32 labelHash) internal pure returns (bytes32) {
        return bytes32(abi.encodePacked(deployer, bytes1(0x00), bytes11(labelHash)));
    }

    function predict(address deployer, bytes32 labelHash, bytes memory initCode) internal view returns (address) {
        bytes32 guarded = keccak256(abi.encode(bytes32(uint256(uint160(deployer))), salt(deployer, labelHash)));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), createX(), guarded, keccak256(initCode)))))
        );
    }

    /// @notice Deploy `initCode` at its permissioned CREATE2 address. When `initData` is non-empty, CreateX
    /// calls it on the new contract in the same call (used for `transferOwnership`).
    function deploy(address deployer, bytes32 labelHash, bytes memory initCode, bytes memory initData)
        internal
        returns (address deployed)
    {
        address cx = createX();
        require(cx.code.length > 0, "CreateX has no code on this chain");
        // CreateX holds its own address in an immutable, so at another address it has another hash. That chain
        // pins its own (release/prereq-chain.sh proves it is canonical once the address is swapped back).
        require(cx.codehash == VM.envOr("GULLYCORE_CREATEX_RUNTIME_HASH", CREATEX_RUNTIME_HASH), "CreateX runtime code is not canonical");
        address predicted = predict(deployer, labelHash, initCode);
        require(predicted.code.length == 0, "the predicted address already has code");
        bytes32 s = salt(deployer, labelHash);
        if (initData.length == 0) {
            deployed = ICoreCreateX(cx).deployCreate2(s, initCode);
        } else {
            deployed = ICoreCreateX(cx).deployCreate2AndInit(s, initCode, initData, ICoreCreateX.Values(0, 0), deployer);
        }
        require(deployed == predicted, "CreateX deployed somewhere other than predicted");
    }
}
