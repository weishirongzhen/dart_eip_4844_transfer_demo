import 'dart:developer';
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dart_kzg_4844_util/dart_kzg_4844_util.dart';
import 'package:http/http.dart';
import 'package:web3dart/web3dart.dart';

const blobTxBlobGasPerBlob = 1 << 17; //128K

/// Target consumable blob gas for data blobs per block (for 1559-like pricing)
const blobTxTargetBlobGasPerBlock = 3 * blobTxBlobGasPerBlob;

const blobTxBlobGaspriceUpdateFraction = 3338477;
const blobTxMinBlobGasprice = 1;
const escalateMultiplier = 10;

class Eip4844 {
  BlobTxSidecar? sidecar;
  static KzgSetting? _kzgSetting;

  static Future<void> init() async {
    await DartKzg4844Util.init();
    _kzgSetting = await KzgSetting.loadFromFile('assets/trusted_setup.json');
  }

  Future<String> transferTest() async {
    String result = 'none';
    String privateKey = 'your private key';
    String rpcUrl = 'your rpc node';

    final client = Web3Client(rpcUrl, Client());

    final credentials = EthPrivateKey.fromHex(privateKey);
    final address = credentials.address;

    print(address.hexEip55);
    print(await client.getBalance(address));

    final gasPrice = await client.getGasPrice();
    final chainId = await client.getChainId();
    final nonce =
        await client.getTransactionCount(address, atBlock: BlockNum.pending());

    print('wtf gasPrice = ${gasPrice.getInWei}');
    print('wtf chainId = ${chainId}');
    print('wtf nonce = ${nonce}');

    /// 普通交易
    // result = await client.sendTransaction(
    //   credentials,
    //   Transaction(
    //     to: address,
    //     gasPrice: gasPrice,
    //     maxGas: 100000,
    //     nonce: nonce,
    //     value: EtherAmount.fromInt(EtherUnit.wei, 10),
    //   ),
    //   chainId: chainId.toInt(),
    // );
    // print('wtf result = ${result}');

    /// Eip 4844
    final blobs = <Blob>[];
    final commitments = <KzgCommitment>[];
    final proofs = <KzgProof>[];
    blobs.add(Blob()); // 全0

    for (var b in blobs) {
      final commit = await Kzg4844.kzgBlobToCommitment(b, _kzgSetting!);
      commitments.add(commit);
      final p = await Kzg4844.kzgComputeBlobKzgProof(b, commit, _kzgSetting!);
      proofs.add(p);
    }

    sidecar = BlobTxSidecar(
      blobs: blobs,
      commitments: commitments,
      proofs: proofs,
    );

    print(hex.encode(sidecar!.blobHashes().first));

    final maxPriorityFeePerGasHex =
        await client.makeRPCCall('eth_maxPriorityFeePerGas');
    BigInt maxPriorityFeePerGasInt = BigInt.parse(
        maxPriorityFeePerGasHex.toString().replaceAll('0x', ''),
        radix: 16);

    print('maxPriorityFeePerGasInt = $maxPriorityFeePerGasInt');
    final ethGasPriceHex = await client.makeRPCCall('eth_gasPrice');
    BigInt maxFeePerGas =
        BigInt.parse(ethGasPriceHex.toString().replaceAll('0x', ''), radix: 16);
    print('maxFeePerGas = $maxFeePerGas');
    final gasLimit = await client.estimateGas(
      sender: address,
      to: address,
      maxFeePerGas: EtherAmount.fromBigInt(EtherUnit.wei, maxFeePerGas),
      maxPriorityFeePerGas:
          EtherAmount.fromBigInt(EtherUnit.wei, maxPriorityFeePerGasInt),
      value: EtherAmount.fromInt(EtherUnit.wei, 0),
    );

    print('gasLimit = $gasLimit');

    final header = await client.getBlockInformationRaw();
    print(
        'excessBlobGas = ${BigInt.parse(header['excessBlobGas'].toString().replaceAll("0x", ""), radix: 16)}');
    print(
        'blobGasUsed = ${BigInt.parse(header['blobGasUsed'].toString().replaceAll("0x", ""), radix: 16)}');
    print('--------------------');

    final parentExcessBlobGas = calcExcessBlobGas(
      BigInt.parse(header['excessBlobGas'].toString().replaceAll('0x', ''),
          radix: 16),
      BigInt.parse(header['blobGasUsed'].toString().replaceAll('0x', ''),
          radix: 16),
    );
    print('parentExcessBlobGas = $parentExcessBlobGas');
    BigInt blobFeeCap = calcBlobFee(parentExcessBlobGas);
    print('blobFeeCap = $blobFeeCap');

    maxPriorityFeePerGasInt =
        maxPriorityFeePerGasInt * BigInt.from(escalateMultiplier);
    maxFeePerGas = maxFeePerGas * BigInt.from(escalateMultiplier);
    blobFeeCap = blobFeeCap * BigInt.from(escalateMultiplier);
    print('-------------');
    print('maxPriorityFeePerGasInt = $maxPriorityFeePerGasInt');
    print('ethGasPriceInt = $maxFeePerGas');
    print('blobFeeCap = $blobFeeCap');

    // final eip1559 = Transaction(
    //   to: address,
    //   maxFeePerGas: EtherAmount.fromBigInt(EtherUnit.wei, ethGasPriceInt),
    //   maxPriorityFeePerGas:
    //       EtherAmount.fromBigInt(EtherUnit.wei, maxPriorityFeePerGasInt),
    //   maxGas: (gasLimit * BigInt.from(1.2)).toInt(),
    //   nonce: nonce,
    //   value: EtherAmount.fromInt(EtherUnit.wei, 10),
    // );
    final eip4844 = Transaction(
      to: address,
      maxFeePerGas: EtherAmount.fromBigInt(EtherUnit.wei, maxFeePerGas),
      maxPriorityFeePerGas:
          EtherAmount.fromBigInt(EtherUnit.wei, maxPriorityFeePerGasInt),
      maxGas: (gasLimit * BigInt.from(12) / BigInt.from(10)).toInt(),
      maxFeePerBlobGas: EtherAmount.fromBigInt(EtherUnit.wei, blobFeeCap),
      blobVersionedHashes: sidecar!.blobHashes(),
      nonce: nonce,
      value: EtherAmount.fromInt(EtherUnit.wei, 111),
      sidecar: Sidecar(
        blobs: sidecar!.blobs.map((e) => e.blob).toList(growable: false),
        commitment: sidecar!.commitments
            .map((e) => e.commitment)
            .toList(growable: false),
        proof: sidecar!.proofs.map((e) => e.proof).toList(growable: false),
      ),
    );
    final signedTx = await client.signTransaction(credentials, eip4844,
        chainId: chainId.toInt());
    final raw = Uint8List(signedTx.length + 1)
      ..[0] = 0x03
      ..setAll(1, signedTx);
    log('["${hex.encode(raw)}"]');

    result = await client.sendTransaction(
      credentials,
      eip4844,
      chainId: chainId.toInt(),
    );

    await client.dispose();

    return result;
  }

  BigInt fakeExponential(BigInt factor, BigInt numerator, BigInt denominator) {
    var output = BigInt.zero;
    var accum = factor * denominator;
    var i = 1;

    while (accum.sign > 0) {
      output += accum;

      accum = accum * numerator ~/ denominator;
      accum = accum ~/ BigInt.from(i);

      i++;
    }
    return output ~/ denominator;
  }

  BigInt calcExcessBlobGas(
    BigInt parentExcessBlobGas,
    BigInt parentBlobGasUsed,
  ) {
    BigInt excessBlobGas = parentExcessBlobGas + parentBlobGasUsed;
    if (excessBlobGas < BigInt.from(blobTxTargetBlobGasPerBlock)) {
      return BigInt.zero;
    }
    return excessBlobGas - BigInt.from(blobTxTargetBlobGasPerBlock);
  }

  BigInt calcBlobFee(BigInt excessBlobGas) {
    return fakeExponential(BigInt.from(blobTxMinBlobGasprice), excessBlobGas,
        BigInt.from(blobTxBlobGaspriceUpdateFraction));
  }
}
