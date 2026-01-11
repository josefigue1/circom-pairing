pragma circom 2.0.3;

include "final_exp.circom";
include "pairing.circom";
include "bls12_381_func.circom";
include "bls12_381_hash_to_G2.circom";

// Part 1: Checks + MapToG2
// Inputs: pubkey, signature, hash
// Output: Hm (public output to be chained to Part2)
// Verifica: range checks, subgroup checks, y calcula Hm = MapToG2(hash) con Hm != infinity
template CoreVerifyPart1(n, k){
    signal input pubkey[2][k];
    signal input signature[2][2][k];
    signal input hash[2][2][k];
    signal output Hm[2][2][k];
     
    var q[50] = get_BLS12_381_prime(n, k);

    component lt[10];
    for(var i=0; i<10; i++){
        lt[i] = BigLessThan(n, k);
        for(var idx=0; idx<k; idx++)
            lt[i].b[idx] <== q[idx];
    }
    for(var idx=0; idx<k; idx++){
        lt[0].a[idx] <== pubkey[0][idx];
        lt[1].a[idx] <== pubkey[1][idx];
        lt[2].a[idx] <== signature[0][0][idx];
        lt[3].a[idx] <== signature[0][1][idx];
        lt[4].a[idx] <== signature[1][0][idx];
        lt[5].a[idx] <== signature[1][1][idx];
        lt[6].a[idx] <== hash[0][0][idx];
        lt[7].a[idx] <== hash[0][1][idx];
        lt[8].a[idx] <== hash[1][0][idx];
        lt[9].a[idx] <== hash[1][1][idx];
    }
    var r = 0;
    for(var i=0; i<10; i++){
        r += lt[i].out;
    }
    r === 10;
    
    component check[5]; 
    for(var i=0; i<5; i++)
        check[i] = RangeCheck2D(n, k); 
    for(var i=0; i<2; i++)for(var idx=0; idx<k; idx++){
        check[0].in[i][idx] <== pubkey[i][idx];
        check[1].in[i][idx] <== signature[0][i][idx];
        check[2].in[i][idx] <== signature[1][i][idx];
        check[3].in[i][idx] <== hash[0][i][idx];
        check[4].in[i][idx] <== hash[1][i][idx];
    }
    
    component pubkey_valid = SubgroupCheckG1(n, k);
    for(var i=0; i<2; i++)for(var idx=0; idx<k; idx++)
        pubkey_valid.in[i][idx] <== pubkey[i][idx];

    component signature_valid = SubgroupCheckG2(n, k);
    for(var i=0; i<2; i++)for(var j=0; j<2; j++)for(var idx=0; idx<k; idx++)
        signature_valid.in[i][j][idx] <== signature[i][j][idx];

    component Hm_component = MapToG2(n, k);
    for(var i=0; i<2; i++)for(var j=0; j<2; j++)for(var idx=0; idx<k; idx++)
        Hm_component.in[i][j][idx] <== hash[i][j][idx];

    Hm_component.isInfinity === 0;
    
    // Assign calculated Hm to output signal
    for(var i=0; i<2; i++)for(var j=0; j<2; j++)for(var idx=0; idx<k; idx++)
        Hm[i][j][idx] <== Hm_component.out[i][j][idx];
}

// Part 2: MillerLoopFp2Two
// Inputs: pubkey, signature, Hm
// Output: miller_out (public output to be chained to Part3)
// Calcula: MillerLoopFp2Two con negación de signature
template CoreVerifyPart2(n, k){
    signal input pubkey[2][k];
    signal input signature[2][2][k];
    signal input Hm[2][2][k];
    signal output miller_out[6][2][k];

    var q[50] = get_BLS12_381_prime(n, k);
    var x = get_BLS12_381_parameter();
    var g1[2][50] = get_generator_G1(n, k); 

    signal neg_s[2][2][k];
    component neg[2];
    for(var j=0; j<2; j++){
        neg[j] = FpNegate(n, k, q); 
        for(var idx=0; idx<k; idx++)
            neg[j].in[idx] <== signature[1][j][idx];
        for(var idx=0; idx<k; idx++){
            neg_s[0][j][idx] <== signature[0][j][idx];
            neg_s[1][j][idx] <== neg[j].out[idx];
        }
    }

    component miller = MillerLoopFp2Two(n, k, [4,4], x, q);
    for(var i=0; i<2; i++)for(var j=0; j<2; j++)for(var idx=0; idx<k; idx++){
        miller.P[0][i][j][idx] <== neg_s[i][j][idx];
        miller.P[1][i][j][idx] <== Hm[i][j][idx];
    }
    for(var i=0; i<2; i++)for(var idx=0; idx<k; idx++){
        miller.Q[0][i][idx] <== g1[i][idx];
        miller.Q[1][i][idx] <== pubkey[i][idx];
    }

    // Assign calculated miller_out to output signal
    for(var i=0; i<6; i++)for(var j=0; j<2; j++)for(var idx=0; idx<k; idx++)
        miller_out[i][j][idx] <== miller.out[i][j][idx];
}

// Part 3: FinalExponentiate + Check == 1
// Input: miller_out (resultado del Miller loop)
// Output: none (solo constriñe que finalexp == 1)
// Verifica: FinalExponentiate(miller_out) == 1
template CoreVerifyPart3(n, k){
    signal input miller_out[6][2][k];

    var q[50] = get_BLS12_381_prime(n, k);

    component finalexp = FinalExponentiate(n, k, q);
    for(var i=0; i<6; i++)for(var j=0; j<2; j++)for(var idx=0; idx<k; idx++)
        finalexp.in[i][j][idx] <== miller_out[i][j][idx];

    component is_valid[6][2][k];
    var total = 12*k;
    for(var i=0; i<6; i++)for(var j=0; j<2; j++)for(var idx=0; idx<k; idx++){
        is_valid[i][j][idx] = IsZero(); 
        if(i==0 && j==0 && idx==0)
            is_valid[i][j][idx].in <== finalexp.out[i][j][idx] - 1;
        else
            is_valid[i][j][idx].in <== finalexp.out[i][j][idx];
        total -= is_valid[i][j][idx].out; 
    }
    component valid = IsZero(); 
    valid.in <== total;
    valid.out === 1;
}


