import 'package:flutter/widgets.dart';
import 'package:get/get.dart';

import '../models/local_ssh_key_candidate.dart';

abstract class KeysControllerBase extends GetxController {
  TextEditingController get pemController;

  RxBool get busy;
  RxString get status;

  RxBool get scanningLocalKeys;
  RxList<LocalSshKeyCandidate> get localKeyCandidates;

  Future<void> load();
  Future<void> save();
  Future<void> deleteKey();
  Future<void> generate();
  Future<void> copyPublicKey();

  Future<void> scanLocalKeys();
  Future<void> useLocalKey(LocalSshKeyCandidate key);
}
