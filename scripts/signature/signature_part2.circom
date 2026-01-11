pragma circom 2.0.3;

include "../../circuits/bls_signature_split.circom";

component main { public [ pubkey, signature, Hm ] } = CoreVerifyPart2(55, 7);


