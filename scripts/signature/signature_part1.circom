pragma circom 2.0.3;

include "../../circuits/bls_signature_split.circom";

component main { public [ Hm, pubkey, signature, hash ] } = CoreVerifyPart1(55, 7);


