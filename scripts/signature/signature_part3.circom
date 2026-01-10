pragma circom 2.0.3;

include "../../circuits/bls_signature_split.circom";

component main { public [ miller_out ] } = CoreVerifyPart3(55, 7);


