// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import { IModule } from "../../modules/base/IModule.sol";

/// @title RoyaltyModule interface
interface IRoyaltyModule is IModule {
    /// @notice Event emitted when a royalty policy is whitelisted
    /// @param royaltyPolicy The address of the royalty policy
    /// @param allowed Indicates if the royalty policy is whitelisted or not
    event RoyaltyPolicyWhitelistUpdated(address royaltyPolicy, bool allowed);

    /// @notice Event emitted when a royalty token is whitelisted
    /// @param token The address of the royalty token
    /// @param allowed Indicates if the royalty token is whitelisted or not
    event RoyaltyTokenWhitelistUpdated(address token, bool allowed);

    /// @notice Event emitted when royalties are paid
    /// @param receiverIpId The ID of IP asset that receives the royalties
    /// @param payerIpId The ID of IP asset that pays the royalties
    /// @param sender The address that pays the royalties on behalf of the payer ID of IP asset
    /// @param token The token that is used to pay the royalties
    /// @param amount The amount that is paid
    event RoyaltyPaid(address receiverIpId, address payerIpId, address sender, address token, uint256 amount);

    /// @notice Event emitted when the license minting fee is paid
    /// @param receiverIpId The ipId that receives the royalties
    /// @param payerAddress The address that pays the royalties
    /// @param token The token that is used to pay the royalties
    /// @param amount The amount paid
    event LicenseMintingFeePaid(address receiverIpId, address payerAddress, address token, uint256 amount);

    /// @notice Event emitted when a royalty policy is registered
    /// @param externalRoyaltyPolicy The address of the external royalty policy
    event ExternalRoyaltyPolicyRegistered(address externalRoyaltyPolicy);

    /// @notice Event emitted when the IP graph limits are updated
    /// @param maxParents The maximum number of parents an IP asset can have
    /// @param maxAncestors The maximum number of ancestors an IP asset can have
    /// @param accumulatedRoyaltyPoliciesLimit The maximum number of accumulated royalty policies an IP asset can have
    event IpGraphLimitsUpdated(uint256 maxParents, uint256 maxAncestors, uint256 accumulatedRoyaltyPoliciesLimit);

    /// @notice Sets the ip graph limits
    /// @dev Enforced to be only callable by the protocol admin
    /// @param parentLimit The maximum number of parents an IP asset can have
    /// @param ancestorLimit The maximum number of ancestors an IP asset can have
    /// @param accumulatedRoyaltyPoliciesLimit The maximum number of accumulated royalty policies an IP asset can have
    function setIpGraphLimits(
        uint256 parentLimit,
        uint256 ancestorLimit,
        uint256 accumulatedRoyaltyPoliciesLimit
    ) external;

    /// @notice Whitelist a royalty policy
    /// @dev Enforced to be only callable by the protocol admin
    /// @param royaltyPolicy The address of the royalty policy
    /// @param allowed Indicates if the royalty policy is whitelisted or not
    function whitelistRoyaltyPolicy(address royaltyPolicy, bool allowed) external;

    /// @notice Whitelist a royalty token
    /// @dev Enforced to be only callable by the protocol admin
    /// @param token The token address
    /// @param allowed Indicates if the token is whitelisted or not
    function whitelistRoyaltyToken(address token, bool allowed) external;

    /// @notice Registers an external royalty policy
    /// @param externalRoyaltyPolicy The address of the external royalty policy
    function registerExternalRoyaltyPolicy(address externalRoyaltyPolicy) external;

    /// @notice Executes royalty related logic on license minting
    /// @dev Enforced to be only callable by LicensingModule
    /// @param ipId The ipId whose license is being minted (licensor)
    /// @param royaltyPolicy The royalty policy address of the license being minted
    /// @param licensePercent The license percentage of the license being minted
    /// @param externalData The external data custom to each the royalty policy
    function onLicenseMinting(
        address ipId,
        address royaltyPolicy,
        uint32 licensePercent,
        bytes calldata externalData
    ) external;

    /// @notice Executes royalty related logic on linking to parents
    /// @dev Enforced to be only callable by LicensingModule
    /// @param ipId The children ipId that is being linked to parents
    /// @param parentIpIds The parent ipIds that the children ipId is being linked to
    /// @param licensesPercent The license percentage of the licenses being minted
    /// @param externalData The external data custom to each the royalty policy
    function onLinkToParents(
        address ipId,
        address[] calldata parentIpIds,
        address[] calldata licenseRoyaltyPolicies,
        uint32[] calldata licensesPercent,
        bytes calldata externalData
    ) external;

    /// @notice Allows the function caller to pay royalties to the receiver IP asset on behalf of the payer IP asset.
    /// @param receiverIpId The ipId that receives the royalties
    /// @param payerIpId The ipId that pays the royalties
    /// @param token The token to use to pay the royalties
    /// @param amount The amount to pay
    function payRoyaltyOnBehalf(address receiverIpId, address payerIpId, address token, uint256 amount) external;

    /// @notice Allows to pay the minting fee for a license
    /// @param receiverIpId The ipId that receives the royalties
    /// @param payerAddress The address that pays the royalties
    /// @param token The token to use to pay the royalties
    /// @param amount The amount to pay
    function payLicenseMintingFee(address receiverIpId, address payerAddress, address token, uint256 amount) external;

    /// @notice Returns the total number of royalty tokens
    function totalRtSupply() external pure returns (uint32);

    /// @notice Indicates if a royalty policy is whitelisted
    /// @param royaltyPolicy The address of the royalty policy
    /// @return isWhitelisted True if the royalty policy is whitelisted
    function isWhitelistedRoyaltyPolicy(address royaltyPolicy) external view returns (bool);

    /// @notice Indicates if an external royalty policy is registered
    /// @param externalRoyaltyPolicy The address of the external royalty policy
    /// @return isRegistered True if the external royalty policy is registered
    function isRegisteredExternalRoyaltyPolicy(address externalRoyaltyPolicy) external view returns (bool);

    /// @notice Indicates if a royalty token is whitelisted
    /// @param token The address of the royalty token
    /// @return isWhitelisted True if the royalty token is whitelisted
    function isWhitelistedRoyaltyToken(address token) external view returns (bool);

    /// @notice Returns the maximum number of parents
    function maxParents() external view returns (uint256);

    /// @notice Returns the maximum number of total ancestors
    function maxAncestors() external view returns (uint256);

    /// @notice Returns the maximum number of accumulated royalty policies an IP asset can have
    function maxAccumulatedRoyaltyPolicies() external view returns (uint256);

    /// @notice Indicates the royalty vault for a given IP asset
    /// @param ipId The ID of IP asset
    function ipRoyaltyVaults(address ipId) external view returns (address);

    /// @notice Returns the accumulated royalty policies for a given IP asset
    /// @param ipId The ID of IP asset
    function accumulatedRoyaltyPolicies(address ipId) external view returns (address[] memory);
}
