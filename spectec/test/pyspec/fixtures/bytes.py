def root_prefix(root: Root) -> bytes:
    return root[:4]


def signing_root(root: Root, domain: Domain) -> Root:
    signing = SigningData(object_root=root, domain=domain)
    return hash_tree_root(signing)


def verify_signature(pubkey: BLSPubkey, message: Root, signature: BLSSignature) -> bool:
    return bls.Verify(pubkey, message, signature)
