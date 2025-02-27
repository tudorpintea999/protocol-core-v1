// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

// external
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { ERC20, IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// contracts
import { IRoyaltyModule } from "../../../../../contracts/interfaces/modules/royalty/IRoyaltyModule.sol";
import { IpRoyaltyVault } from "../../../../../contracts/modules/royalty/policies/IpRoyaltyVault.sol";
// solhint-disable-next-line max-line-length
import { IRoyaltyPolicyLAP } from "../../../../../contracts/interfaces/modules/royalty/policies/LAP/IRoyaltyPolicyLAP.sol";
import { Errors } from "../../../../../contracts/lib/Errors.sol";
import { PILFlavors } from "../../../../../contracts/lib/PILFlavors.sol";

// test
import { BaseIntegration } from "../../BaseIntegration.t.sol";

contract Flows_Integration_Disputes is BaseIntegration {
    using EnumerableSet for EnumerableSet.UintSet;
    using Strings for *;

    mapping(uint256 tokenId => address ipAccount) internal ipAcct;

    uint32 internal defaultCommRevShare = 10 * 10 ** 6; // 10%
    uint256 internal mintingFee = 7 ether;
    uint256 internal commRemixTermsId;

    function setUp() public override {
        super.setUp();

        commRemixTermsId = registerSelectedPILicenseTerms(
            "commercial_remix",
            PILFlavors.commercialRemix({
                mintingFee: mintingFee,
                commercialRevShare: defaultCommRevShare,
                royaltyPolicy: address(royaltyPolicyLAP),
                currencyToken: address(erc20)
            })
        );

        // Register an original work with both policies set
        mockNFT.mintId(u.alice, 1);
        mockNFT.mintId(u.bob, 2);
        mockNFT.mintId(u.carl, 3);
    }

    function test_Integration_Royalty() public {
        {
            vm.startPrank(u.alice);

            ipAcct[1] = registerIpAccount(mockNFT, 1, u.alice);
            vm.label(ipAcct[1], "IPAccount1");

            licensingModule.attachLicenseTerms(ipAcct[1], address(pilTemplate), commRemixTermsId);
            vm.stopPrank();
        }

        // Bob mints 1 license of policy "pil-commercial-remix" from IPAccount1 and registers the derivative IP for
        // NFT tokenId 2.
        {
            vm.startPrank(u.bob);

            uint256 mintAmount = 3;
            erc20.approve(address(royaltyModule), mintAmount * mintingFee);

            uint256[] memory licenseIds = new uint256[](3);

            vm.expectEmit(address(royaltyModule));
            emit IRoyaltyModule.LicenseMintingFeePaid(ipAcct[1], u.bob, address(erc20), mintAmount * mintingFee);

            licenseIds[0] = licensingModule.mintLicenseTokens({
                licensorIpId: ipAcct[1],
                licenseTemplate: address(pilTemplate),
                licenseTermsId: commRemixTermsId,
                amount: mintAmount,
                receiver: u.bob,
                royaltyContext: ""
            }); // first license minted
            licenseIds[1] = licenseIds[0] + 1; // second license minted
            licenseIds[2] = licenseIds[0] + 2; // third license minted

            ipAcct[2] = registerIpAccount(address(mockNFT), 2, u.bob);

            vm.expectRevert(
                abi.encodeWithSelector(
                    Errors.LicenseRegistry__DuplicateLicense.selector,
                    ipAcct[1],
                    address(pilTemplate),
                    commRemixTermsId
                )
            );
            licensingModule.registerDerivativeWithLicenseTokens(ipAcct[2], licenseIds, "");

            // can link max two
            uint256[] memory licenseIdsMax = new uint256[](1);
            licenseIdsMax[0] = licenseIds[0];

            registerDerivativeWithLicenseTokens(ipAcct[2], licenseIdsMax, "", u.bob);

            vm.stopPrank();
        }

        // Carl mints 1 license of policy "pil-commercial-remix" from IPAccount1 and IPAccount2 and registers the
        // derivative IP for NFT tokenId 3. Thus, IPAccount3 is a derivative of both IPAccount1 and IPAccount2.
        // More precisely, IPAccount1 is a grandparent and IPAccount2 is a parent of IPAccount3.
        {
            vm.startPrank(u.carl);

            uint256 mintAmount = 1;
            uint256[] memory licenseIds = new uint256[](2);

            erc20.approve(address(royaltyModule), 2 * mintAmount * mintingFee);

            vm.expectEmit(address(royaltyModule));
            emit IRoyaltyModule.LicenseMintingFeePaid(ipAcct[1], u.carl, address(erc20), mintAmount * mintingFee);
            licenseIds[0] = licensingModule.mintLicenseTokens({
                licensorIpId: ipAcct[1],
                licenseTemplate: address(pilTemplate),
                licenseTermsId: commRemixTermsId,
                amount: mintAmount,
                receiver: u.carl,
                royaltyContext: ""
            });

            vm.expectEmit(address(royaltyModule));
            emit IRoyaltyModule.LicenseMintingFeePaid(ipAcct[2], u.carl, address(erc20), mintAmount * mintingFee);
            licenseIds[1] = licensingModule.mintLicenseTokens({
                licensorIpId: ipAcct[2], // parent, is child IP of ipAcct[1]
                licenseTemplate: address(pilTemplate),
                licenseTermsId: commRemixTermsId,
                amount: mintAmount,
                receiver: u.carl,
                royaltyContext: ""
            });

            ipAcct[3] = registerIpAccount(address(mockNFT), 3, u.carl);
            registerDerivativeWithLicenseTokens(ipAcct[3], licenseIds, "", u.carl);
            vm.stopPrank();
        }

        // IPAccount1 and IPAccount2 have commercial policy, of which IPAccount3 has used to mint licenses and link.
        // Thus, any payment to IPAccount3 will get split to IPAccount1 and IPAccount2 accordingly to policy.

        uint256 totalPaymentToIpAcct3;

        // A new user, who likes IPAccount3, decides to pay IPAccount3 some royalty (1 token).
        {
            address newUser = address(0xbeef);
            vm.startPrank(newUser);

            mockToken.mint(newUser, 1 ether);

            mockToken.approve(address(royaltyModule), 1 ether);
            // ipAcct[3] is the receiver, the actual token is paid by the caller (newUser).
            royaltyModule.payRoyaltyOnBehalf(ipAcct[3], ipAcct[3], address(mockToken), 1 ether);
            totalPaymentToIpAcct3 += 1 ether;

            vm.stopPrank();
        }

        // Owner of IPAccount2, Bob, claims his RTs from IPAccount3 vault
        {
            vm.startPrank(u.bob);

            ERC20[] memory tokens = new ERC20[](1);
            tokens[0] = mockToken;

            address ipRoyaltyVault3 = royaltyModule.ipRoyaltyVaults(ipAcct[3]);
            address ipRoyaltyVault2 = royaltyModule.ipRoyaltyVaults(ipAcct[2]);

            vm.warp(block.timestamp + 7 days + 1);
            IpRoyaltyVault(ipRoyaltyVault3).snapshot();

            // Expect 10% (10_000_000) because ipAcct[2] has only one parent (IPAccount1), with 10% absolute royalty.

            uint256[] memory snapshotsToClaim = new uint256[](1);
            snapshotsToClaim[0] = 1;
            royaltyPolicyLAP.claimBySnapshotBatchAsSelf(snapshotsToClaim, address(mockToken), ipAcct[3]);

            vm.expectEmit(ipRoyaltyVault3);
            emit IERC20.Transfer({ from: address(royaltyPolicyLAP), to: ipRoyaltyVault2, value: 10_000_000 });

            vm.expectEmit(address(royaltyPolicyLAP));
            emit IRoyaltyPolicyLAP.RoyaltyTokensCollected(ipAcct[3], ipAcct[2], 10_000_000);

            royaltyPolicyLAP.collectRoyaltyTokens(ipAcct[3], ipAcct[2]);
        }

        // Owner of IPAccount1, Alice, claims her RTs from IPAccount2 and IPAccount3 vaults
        {
            vm.startPrank(address(100));

            ERC20[] memory tokens = new ERC20[](1);
            tokens[0] = mockToken;

            address ipRoyaltyVault1 = royaltyModule.ipRoyaltyVaults(ipAcct[1]);
            address ipRoyaltyVault2 = royaltyModule.ipRoyaltyVaults(ipAcct[2]);
            address ipRoyaltyVault3 = royaltyModule.ipRoyaltyVaults(ipAcct[3]);

            vm.warp(block.timestamp + 7 days + 1);
            IpRoyaltyVault(ipRoyaltyVault2).snapshot();

            // IPAccount1 should expect 10% absolute royalty from its children (IPAccount2)
            // and 20% from its grandchild (IPAccount3) and so on.

            uint256[] memory snapshotsToClaim = new uint256[](1);
            snapshotsToClaim[0] = 1;
            royaltyPolicyLAP.claimBySnapshotBatchAsSelf(snapshotsToClaim, address(mockToken), ipAcct[2]);

            vm.expectEmit(ipRoyaltyVault2);
            emit IERC20.Transfer({ from: address(royaltyPolicyLAP), to: ipRoyaltyVault1, value: 10_000_000 });
            vm.expectEmit(address(royaltyPolicyLAP));
            emit IRoyaltyPolicyLAP.RoyaltyTokensCollected(ipAcct[2], ipAcct[1], 10_000_000);
            royaltyPolicyLAP.collectRoyaltyTokens(ipAcct[2], ipAcct[1]);

            vm.expectEmit(ipRoyaltyVault3);
            emit IERC20.Transfer({ from: address(royaltyPolicyLAP), to: ipRoyaltyVault1, value: 20_000_000 });
            vm.expectEmit(address(royaltyPolicyLAP));
            emit IRoyaltyPolicyLAP.RoyaltyTokensCollected(ipAcct[3], ipAcct[1], 20_000_000);
            royaltyPolicyLAP.collectRoyaltyTokens(ipAcct[3], ipAcct[1]);
        }

        // Alice using IPAccount1 takes snapshot on IPAccount2 vault and claims her revenue from both
        // IPAccount2 and IPAccount3
        {
            vm.startPrank(ipAcct[1]);

            address ipRoyaltyVault1 = royaltyModule.ipRoyaltyVaults(ipAcct[1]);

            address[] memory tokens = new address[](1);
            tokens[0] = address(mockToken);

            IpRoyaltyVault(ipRoyaltyVault1).snapshot();

            IpRoyaltyVault(ipRoyaltyVault1).claimRevenueByTokenBatch(1, tokens);
        }
    }
}
