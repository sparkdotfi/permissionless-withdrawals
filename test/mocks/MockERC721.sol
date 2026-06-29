// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.34;

// Minimal ERC721 mock with a payable safeTransferFrom so recoverERC721 can forward msg.value.
// A standard (OZ) ERC721 cannot be used here: its safeTransferFrom is nonpayable and Solidity
// forbids overriding it to payable.
contract MockERC721 {

    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 tokenId) external {
        ownerOf[tokenId] = to;
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external payable {
        require(ownerOf[tokenId] == from, "MockERC721/not-owner");
        ownerOf[tokenId] = to;
    }

}
