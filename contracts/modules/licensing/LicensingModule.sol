// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

// external
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { IIPAccount } from "../../interfaces/IIPAccount.sol";
import { IModule } from "../../interfaces/modules/base/IModule.sol";
import { ILicensingModule } from "../../interfaces/modules/licensing/ILicensingModule.sol";
import { IIPAccountRegistry } from "../../interfaces/registries/IIPAccountRegistry.sol";
import { IDisputeModule } from "../../interfaces/modules/dispute/IDisputeModule.sol";
import { ILicenseRegistry } from "../../interfaces/registries/ILicenseRegistry.sol";
import { Errors } from "../../lib/Errors.sol";
import { Licensing } from "../../lib/Licensing.sol";
import { IPAccountChecker } from "../../lib/registries/IPAccountChecker.sol";
import { RoyaltyModule } from "../../modules/royalty/RoyaltyModule.sol";
import { AccessControlled } from "../../access/AccessControlled.sol";
import { LICENSING_MODULE_KEY } from "../../lib/modules/Module.sol";
import { BaseModule } from "../BaseModule.sol";
import { ILicenseTemplate } from "../../interfaces/modules/licensing/ILicenseTemplate.sol";
import { IPAccountStorageOps } from "../../lib/IPAccountStorageOps.sol";
import { ILicenseToken } from "../../interfaces/ILicenseToken.sol";
import { ProtocolPausableUpgradeable } from "../../pause/ProtocolPausableUpgradeable.sol";
import { ILicensingHook } from "../..//interfaces/modules/licensing/ILicensingHook.sol";
import { IModuleRegistry } from "../../interfaces/registries/IModuleRegistry.sol";

/// @title Licensing Module
/// @notice Licensing module is the main entry point for the licensing system. It is responsible for:
/// - Attaching license terms to IP assets
/// - Minting license Tokens
/// - Registering derivatives
contract LicensingModule is
    AccessControlled,
    ILicensingModule,
    BaseModule,
    ReentrancyGuardUpgradeable,
    ProtocolPausableUpgradeable,
    UUPSUpgradeable
{
    using ERC165Checker for address;
    using IPAccountChecker for IIPAccountRegistry;
    using EnumerableSet for EnumerableSet.UintSet;
    using EnumerableSet for EnumerableSet.AddressSet;
    using Strings for *;
    using IPAccountStorageOps for IIPAccount;

    /// @inheritdoc IModule
    string public constant override name = LICENSING_MODULE_KEY;

    /// @notice Returns the canonical protocol-wide RoyaltyModule
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    RoyaltyModule public immutable ROYALTY_MODULE;

    /// @notice Returns the canonical protocol-wide LicenseRegistry
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    ILicenseRegistry public immutable LICENSE_REGISTRY;

    /// @notice Returns the protocol-wide dispute module
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IDisputeModule public immutable DISPUTE_MODULE;

    /// @notice Returns the License NFT
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    ILicenseToken public immutable LICENSE_NFT;

    /// @notice Returns the protocol-wide ModuleRegistry
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IModuleRegistry public immutable MODULE_REGISTRY;

    // keccak256(abi.encode(uint256(keccak256("story-protocol.LicensingModule")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant LicensingModuleStorageLocation =
        0x0f7178cb62e4803c52d40f70c08a6f88d6ee1af1838d58e0c83a222a6c3d3100;

    /// Constructor
    /// @param accessController The address of the AccessController contract
    /// @param ipAccountRegistry The address of the IPAccountRegistry contract
    /// @param royaltyModule The address of the RoyaltyModule contract
    /// @param licenseRegistry The address of the LicenseRegistry contract
    /// @param disputeModule The address of the DisputeModule contract
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address accessController,
        address ipAccountRegistry,
        address moduleRegistry,
        address royaltyModule,
        address licenseRegistry,
        address disputeModule,
        address licenseToken
    ) AccessControlled(accessController, ipAccountRegistry) {
        if (royaltyModule == address(0)) revert Errors.LicensingModule__ZeroRoyaltyModule();
        if (licenseRegistry == address(0)) revert Errors.LicensingModule__ZeroLicenseRegistry();
        if (disputeModule == address(0)) revert Errors.LicensingModule__ZeroDisputeModule();
        if (licenseToken == address(0)) revert Errors.LicensingModule__ZeroLicenseToken();
        if (moduleRegistry == address(0)) revert Errors.LicensingModule__ZeroModuleRegistry();
        MODULE_REGISTRY = IModuleRegistry(moduleRegistry);
        ROYALTY_MODULE = RoyaltyModule(royaltyModule);
        LICENSE_REGISTRY = ILicenseRegistry(licenseRegistry);
        DISPUTE_MODULE = IDisputeModule(disputeModule);
        LICENSE_NFT = ILicenseToken(licenseToken);
        _disableInitializers();
    }

    /// @notice initializer for this implementation contract
    /// @param accessManager The address of the protocol admin roles contract
    function initialize(address accessManager) public initializer {
        if (accessManager == address(0)) {
            revert Errors.LicensingModule__ZeroAccessManager();
        }
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        __ProtocolPausable_init(accessManager);
    }

    /// @notice Attaches license terms to an IP.
    /// the function must be called by the IP owner or an authorized operator.
    /// @param ipId The IP ID.
    /// @param licenseTemplate The address of the license template.
    /// @param licenseTermsId The ID of the license terms.
    function attachLicenseTerms(
        address ipId,
        address licenseTemplate,
        uint256 licenseTermsId
    ) external verifyPermission(ipId) {
        _verifyIpNotDisputed(ipId);
        LICENSE_REGISTRY.attachLicenseTermsToIp(ipId, licenseTemplate, licenseTermsId);
        emit LicenseTermsAttached(msg.sender, ipId, licenseTemplate, licenseTermsId);
    }

    /// @notice Mints license tokens for the license terms attached to an IP.
    /// The license tokens are minted to the receiver.
    /// The license terms must be attached to the IP before calling this function.
    /// But it can mint license token of default license terms without attaching the default license terms,
    /// since it is attached to all IPs by default.
    /// IP owners can mint license tokens for their IPs for arbitrary license terms
    /// without attaching the license terms to IP.
    /// It might require the caller pay the minting fee, depending on the license terms or configured by the iP owner.
    /// The minting fee is paid in the minting fee token specified in the license terms or configured by the IP owner.
    /// IP owners can configure the minting fee of their IPs or
    /// configure the minting fee module to determine the minting fee.
    /// IP owners can configure the receiver check module to determine the receiver of the minted license tokens.
    /// @param licensorIpId The licensor IP ID.
    /// @param licenseTemplate The address of the license template.
    /// @param licenseTermsId The ID of the license terms within the license template.
    /// @param amount The amount of license tokens to mint.
    /// @param receiver The address of the receiver.
    /// @param royaltyContext The context of the royalty.
    /// @return startLicenseTokenId The start ID of the minted license tokens.
    function mintLicenseTokens(
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        uint256 amount,
        address receiver,
        bytes calldata royaltyContext
    ) external whenNotPaused nonReentrant returns (uint256 startLicenseTokenId) {
        if (amount == 0) {
            revert Errors.LicensingModule__MintAmountZero();
        }
        if (receiver == address(0)) {
            revert Errors.LicensingModule__ReceiverZeroAddress();
        }
        if (!IP_ACCOUNT_REGISTRY.isIpAccount(licensorIpId)) {
            revert Errors.LicensingModule__LicensorIpNotRegistered();
        }
        _verifyIpNotDisputed(licensorIpId);
        Licensing.LicensingConfig memory lsc = LICENSE_REGISTRY.verifyMintLicenseToken(
            licensorIpId,
            licenseTemplate,
            licenseTermsId,
            _hasPermission(licensorIpId)
        );
        uint256 mintingFeeByHook = 0;
        if (lsc.licensingHook != address(0)) {
            mintingFeeByHook = ILicensingHook(lsc.licensingHook).beforeMintLicenseTokens(
                msg.sender,
                licensorIpId,
                licenseTemplate,
                licenseTermsId,
                amount,
                receiver,
                lsc.hookData
            );
        }

        _payMintingFee(licensorIpId, licenseTemplate, licenseTermsId, amount, royaltyContext, lsc, mintingFeeByHook);

        if (!ILicenseTemplate(licenseTemplate).verifyMintLicenseToken(licenseTermsId, receiver, licensorIpId, amount)) {
            revert Errors.LicensingModule__LicenseDenyMintLicenseToken(licenseTemplate, licenseTermsId, licensorIpId);
        }

        startLicenseTokenId = LICENSE_NFT.mintLicenseTokens(
            licensorIpId,
            licenseTemplate,
            licenseTermsId,
            amount,
            msg.sender,
            receiver
        );

        emit LicenseTokensMinted(
            msg.sender,
            licensorIpId,
            licenseTemplate,
            licenseTermsId,
            amount,
            receiver,
            startLicenseTokenId
        );
    }

    /// @notice Registers a derivative directly with parent IP's license terms, without needing license tokens,
    /// and attaches the license terms of the parent IPs to the derivative IP.
    /// The license terms must be attached to the parent IP before calling this function.
    /// All IPs attached default license terms by default.
    /// The derivative IP owner must be the caller or an authorized operator.
    /// @dev The derivative IP is registered with license terms minted from the parent IP's license terms.
    /// @param childIpId The derivative IP ID.
    /// @param parentIpIds The parent IP IDs.
    /// @param licenseTermsIds The IDs of the license terms that the parent IP supports.
    /// @param licenseTemplate The address of the license template of the license terms Ids.
    /// @param royaltyContext The context of the royalty.
    function registerDerivative(
        address childIpId,
        address[] calldata parentIpIds,
        uint256[] calldata licenseTermsIds,
        address licenseTemplate,
        bytes calldata royaltyContext
    ) external whenNotPaused nonReentrant verifyPermission(childIpId) {
        if (parentIpIds.length != licenseTermsIds.length) {
            revert Errors.LicensingModule__LicenseTermsLengthMismatch(parentIpIds.length, licenseTermsIds.length);
        }
        if (parentIpIds.length == 0) {
            revert Errors.LicensingModule__NoParentIp();
        }

        _verifyIpNotDisputed(childIpId);

        // Check the compatibility of all license terms (specified by 'licenseTermsIds') across all parent IPs.
        // All license terms must be compatible with each other.
        // Verify that the derivative IP is permitted under all license terms from the parent IPs.
        address childIpOwner = IIPAccount(payable(childIpId)).owner();
        ILicenseTemplate lct = ILicenseTemplate(licenseTemplate);
        if (!lct.verifyRegisterDerivativeForAllParents(childIpId, parentIpIds, licenseTermsIds, childIpOwner)) {
            revert Errors.LicensingModule__LicenseNotCompatibleForDerivative(childIpId);
        }

        // Ensure none of the parent IPs have expired.
        // Confirm that each parent IP has the license terms attached as specified by 'licenseTermsIds'
        // or default license terms.
        // Ensure the derivative IP is not included in the list of parent IPs.
        // Validate that none of the parent IPs are disputed.
        // If any of the above conditions are not met, revert the transaction. If all conditions are met, proceed.
        // Attach all license terms from the parent IPs to the derivative IP.
        // Set the derivative IP as a derivative of the parent IPs.
        // Set the expiration timestamp for the derivative IP by invoking the license template to calculate
        // the earliest expiration time among all license terms.
        LICENSE_REGISTRY.registerDerivativeIp(childIpId, parentIpIds, licenseTemplate, licenseTermsIds, false);
        // Process the payment for the minting fee.
        (address[] memory royaltyPolicies, uint32[] memory royaltyPercents) = _payMintingFeeForAllParentIps(
            childIpId,
            parentIpIds,
            licenseTermsIds,
            licenseTemplate,
            childIpOwner,
            royaltyContext
        );
        // emit event
        emit DerivativeRegistered(
            msg.sender,
            childIpId,
            new uint256[](0),
            parentIpIds,
            licenseTermsIds,
            licenseTemplate
        );

        if (royaltyPolicies.length == 0 || royaltyPolicies[0] == address(0)) return;
        ROYALTY_MODULE.onLinkToParents(childIpId, parentIpIds, royaltyPolicies, royaltyPercents, royaltyContext);
    }

    /// @notice Registers a derivative with license tokens.
    /// the derivative IP is registered with license tokens minted from the parent IP's license terms.
    /// the license terms of the parent IPs issued with license tokens are attached to the derivative IP.
    /// the caller must be the derivative IP owner or an authorized operator.
    /// @param childIpId The derivative IP ID.
    /// @param licenseTokenIds The IDs of the license tokens.
    /// @param royaltyContext The context of the royalty.
    function registerDerivativeWithLicenseTokens(
        address childIpId,
        uint256[] calldata licenseTokenIds,
        bytes calldata royaltyContext
    ) external nonReentrant whenNotPaused verifyPermission(childIpId) {
        if (licenseTokenIds.length == 0) {
            revert Errors.LicensingModule__NoLicenseToken();
        }

        // Ensure the license token has not expired.
        // Confirm that the license token has not been revoked.
        // Validate that the owner of the derivative IP is also the owner of the license tokens.
        address childIpOwner = IIPAccount(payable(childIpId)).owner();
        (address licenseTemplate, address[] memory parentIpIds, uint256[] memory licenseTermsIds) = LICENSE_NFT
            .validateLicenseTokensForDerivative(msg.sender, childIpId, licenseTokenIds);

        _verifyIpNotDisputed(childIpId);

        // Verify that the derivative IP is permitted under all license terms from the parent IPs.
        // Check the compatibility of all licenses
        ILicenseTemplate lct = ILicenseTemplate(licenseTemplate);
        if (!lct.verifyRegisterDerivativeForAllParents(childIpId, parentIpIds, licenseTermsIds, childIpOwner)) {
            revert Errors.LicensingModule__LicenseTokenNotCompatibleForDerivative(childIpId, licenseTokenIds);
        }

        // Verify that none of the parent IPs have expired.
        // Validate that none of the parent IPs are disputed.
        // Ensure that the derivative IP does not have any existing licenses attached.
        // Validate that the derivative IP is not included in the list of parent IPs.
        // Confirm that the derivative IP does not already have any parent IPs.
        // If any of the above conditions are not met, revert the transaction. If all conditions are met, proceed.
        // Attach all license terms from the parent IPs to the derivative IP.
        // Set the derivative IP as a derivative of the parent IPs.
        // Set the expiration timestamp for the derivative IP to match the earliest expiration time of
        // all license terms.
        LICENSE_REGISTRY.registerDerivativeIp(childIpId, parentIpIds, licenseTemplate, licenseTermsIds, true);

        // Confirm that the royalty policies defined in all license terms of the parent IPs are identical.
        address[] memory rPolicies = new address[](parentIpIds.length);
        uint32[] memory rPercents = new uint32[](parentIpIds.length);
        for (uint256 i = 0; i < parentIpIds.length; i++) {
            (address royaltyPolicy, uint32 royaltyPercent, , ) = lct.getRoyaltyPolicy(licenseTermsIds[i]);
            rPercents[i] = royaltyPercent;
            rPolicies[i] = royaltyPolicy;
        }

        if (rPolicies.length != 0 && rPolicies[0] != address(0)) {
            // Notify the royalty module
            ROYALTY_MODULE.onLinkToParents(childIpId, parentIpIds, rPolicies, rPercents, royaltyContext);
        }
        // burn license tokens
        LICENSE_NFT.burnLicenseTokens(childIpOwner, licenseTokenIds);
        emit DerivativeRegistered(
            msg.sender,
            childIpId,
            licenseTokenIds,
            parentIpIds,
            licenseTermsIds,
            licenseTemplate
        );
    }

    /// @notice Sets the licensing configuration for a specific license terms of an IP.
    /// If both licenseTemplate and licenseTermsId are not specified then the licensing config apply
    /// to all licenses of given IP.
    /// @param ipId The address of the IP for which the configuration is being set.
    /// @param licenseTemplate The address of the license template used.
    /// If not specified, the configuration applies to all licenses.
    /// @param licenseTermsId The ID of the license terms within the license template.
    /// If not specified, the configuration applies to all licenses.
    /// @param licensingConfig The licensing configuration for the license.
    function setLicensingConfig(
        address ipId,
        address licenseTemplate,
        uint256 licenseTermsId,
        Licensing.LicensingConfig memory licensingConfig
    ) external verifyPermission(ipId) whenNotPaused {
        if (
            licensingConfig.licensingHook != address(0) &&
            (!licensingConfig.licensingHook.supportsInterface(type(ILicensingHook).interfaceId) ||
                !MODULE_REGISTRY.isRegistered(licensingConfig.licensingHook))
        ) {
            revert Errors.LicensingModule__InvalidLicensingHook(licensingConfig.licensingHook);
        }
        if (licenseTemplate == address(0) && licenseTermsId == 0) {
            LICENSE_REGISTRY.setLicensingConfigForIp(ipId, licensingConfig);
        } else if (licenseTemplate != address(0) && licenseTermsId != 0) {
            LICENSE_REGISTRY.setLicensingConfigForLicense(ipId, licenseTemplate, licenseTermsId, licensingConfig);
        } else {
            revert Errors.LicensingModule__InvalidLicenseTermsId(licenseTemplate, licenseTermsId);
        }
    }

    /// @dev pay minting fee for all parent IPs
    /// This function is called by registerDerivative
    /// It pays the minting fee for all parent IPs through the royalty module
    /// finally returns the common royalty policy and data for the parent IPs
    function _payMintingFeeForAllParentIps(
        address childIpId,
        address[] calldata parentIpIds,
        uint256[] calldata licenseTermsIds,
        address licenseTemplate,
        address childIpOwner,
        bytes calldata royaltyContext
    ) private returns (address[] memory royaltyPolicies, uint32[] memory royaltyPercents) {
        royaltyPolicies = new address[](licenseTermsIds.length);
        royaltyPercents = new uint32[](licenseTermsIds.length);
        // pay minting fee for all parent IPs
        for (uint256 i = 0; i < parentIpIds.length; i++) {
            (address royaltyPolicy, uint32 royaltyPercent) = _executeLicensingHookAndPayMintingFee(
                childIpId,
                parentIpIds[i],
                licenseTemplate,
                licenseTermsIds[i],
                childIpOwner,
                royaltyContext
            );
            royaltyPolicies[i] = royaltyPolicy;
            royaltyPercents[i] = royaltyPercent;
        }
    }

    function _executeLicensingHookAndPayMintingFee(
        address childIpId,
        address parentIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        address childIpOwner,
        bytes calldata royaltyContext
    ) private returns (address royaltyPolicy, uint32 royaltyPercent) {
        Licensing.LicensingConfig memory lsc = LICENSE_REGISTRY.getLicensingConfig(
            parentIpId,
            licenseTemplate,
            licenseTermsId
        );
        // check childIpOwner is qualified with check receiver module
        uint256 mintingFeeByHook = 0;
        if (lsc.licensingHook != address(0)) {
            mintingFeeByHook = ILicensingHook(lsc.licensingHook).beforeRegisterDerivative(
                msg.sender,
                childIpId,
                parentIpId,
                licenseTemplate,
                licenseTermsId,
                lsc.hookData
            );
        }
        (royaltyPolicy, royaltyPercent) = _payMintingFee(
            parentIpId,
            licenseTemplate,
            licenseTermsId,
            1,
            royaltyContext,
            lsc,
            mintingFeeByHook
        );
    }

    /// @dev pay minting fee for an parent IP
    /// This function is called by mintLicenseTokens and registerDerivative
    /// It initialize royalty module and pays the minting fee for the parent IP through the royalty module
    /// finally returns the royalty policy and data for the parent IP
    /// @param parentIpId The parent IP ID.
    /// @param licenseTemplate The address of the license template.
    /// @param licenseTermsId The ID of the license terms.
    /// @param amount The amount of license tokens to mint.
    /// @param royaltyContext The context of the royalty.
    /// @param licensingConfig The minting license config
    /// @return royaltyPolicy The address of the royalty policy.
    /// @return royaltyPercent The license royalty percentage
    function _payMintingFee(
        address parentIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        uint256 amount,
        bytes calldata royaltyContext,
        Licensing.LicensingConfig memory licensingConfig,
        uint256 mintingFeeByHook
    ) private returns (address royaltyPolicy, uint32 royaltyPercent) {
        ILicenseTemplate lct = ILicenseTemplate(licenseTemplate);
        uint256 mintingFeeByLicense = 0;
        address currencyToken = address(0);
        (royaltyPolicy, royaltyPercent, mintingFeeByLicense, currencyToken) = lct.getRoyaltyPolicy(licenseTermsId);

        if (royaltyPolicy != address(0)) {
            ROYALTY_MODULE.onLicenseMinting(parentIpId, royaltyPolicy, royaltyPercent, royaltyContext);
            uint256 tmf = _getTotalMintingFee(licensingConfig, mintingFeeByHook, mintingFeeByLicense, amount);
            // pay minting fee
            if (tmf > 0) {
                ROYALTY_MODULE.payLicenseMintingFee(parentIpId, msg.sender, currencyToken, tmf);
            }
        }
    }

    /// @dev get total minting fee
    /// There are 3 places to get the minting fee: license terms, MintingLicenseConfig, MintingFeeModule
    /// The order of priority is MintingFeeModule > MintingLicenseConfig >  > license terms
    /// @param licensingConfig The minting license config
    /// @param mintingFeeSetByHook The minting fee set by the hook.
    /// @param mintingFeeSetByLicenseTerms The minting fee set by the license terms.
    /// @param amount The amount of license tokens to mint.
    function _getTotalMintingFee(
        Licensing.LicensingConfig memory licensingConfig,
        uint256 mintingFeeSetByHook,
        uint256 mintingFeeSetByLicenseTerms,
        uint256 amount
    ) private view returns (uint256) {
        if (!licensingConfig.isSet) return mintingFeeSetByLicenseTerms * amount;
        if (licensingConfig.licensingHook == address(0)) return licensingConfig.mintingFee * amount;
        return mintingFeeSetByHook;
    }

    /// @dev Verifies if the IP is disputed
    function _verifyIpNotDisputed(address ipId) private view {
        if (DISPUTE_MODULE.isIpTagged(ipId)) {
            revert Errors.LicensingModule__DisputedIpId();
        }
    }

    /// @dev Hook to authorize the upgrade according to UUPSUpgradeable
    /// @param newImplementation The address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override restricted {}
}
