// RemoteSDP implementation for handling SDP manipulation in Unified Plan mode

import 'package:collection/collection.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sdp_transform/sdp_transform.dart';
import 'package:mediasoup_client_flutter/src/producer.dart';
import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';
import 'package:mediasoup_client_flutter/src/sctp_parameters.dart';
import 'package:mediasoup_client_flutter/src/transport.dart';
import 'package:mediasoup_client_flutter/src/common/logger.dart';
import 'package:mediasoup_client_flutter/src/handlers/sdp/media_section.dart';
import 'package:sdp_transform/sdp_transform.dart';

Logger _logger = Logger('RemoteSdp');

/// Represents a media section index and optional reuse MID
class MediaSectionIdx {
  final int idx;
  final String? reuseMid;

  const MediaSectionIdx({
    required this.idx,
    this.reuseMid,
  });

  factory MediaSectionIdx.fromMap(Map<String, dynamic> data) {
    return MediaSectionIdx(
      idx: data['idx'] as int,
      reuseMid: data['reuseMid'] as String?,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'idx': idx,
      if (reuseMid != null) 'reuseMid': reuseMid,
    };
  }

  @override
  String toString() => 'MediaSectionIdx(${toMap()})';
}

/// RemoteSdp handles the SDP received from the remote peer.
class RemoteSdp {
  final IceParameters _iceParameters;
  final List<IceCandidate> _iceCandidates;
  final DtlsParameters _dtlsParameters;
  final SctpParameters? _sctpParameters;
  final PlainRtpParameters? _plainRtpParameters;
  final bool _planB;

  final List<Map<String, dynamic>> _mediaSections = [];
  final Map<String, int> _midToIndex = {};
  String? _firstMid;

  Map<String, dynamic> _sdpObject = {
    'version': 0,
    'origin': {
      'username': '-',
      'sessionId': DateTime.now().millisecondsSinceEpoch,
      'sessionVersion': 2,
      'netType': 'IN',
      'ipVer': 4,
      'address': '0.0.0.0'
    },
    'name': '-',
    'timing': {'start': 0, 'stop': 0},
    'media': [],
    'attributes': [],
  };

  RemoteSdp({
    required IceParameters iceParameters,
    required List<IceCandidate> iceCandidates,
    required DtlsParameters dtlsParameters,
    SctpParameters? sctpParameters,
    PlainRtpParameters? plainRtpParameters,
    bool planB = false,
  })  : _iceParameters = iceParameters,
        _iceCandidates = List.unmodifiable(iceCandidates),
        _dtlsParameters = dtlsParameters,
        _sctpParameters = sctpParameters,
        _plainRtpParameters = plainRtpParameters,
        _planB = planB {
    _logger.debug('constructor() [planB:$_planB]');

    _setupSessionLevelIceParameters();
    _setupSessionLevelDtlsParameters();
  }

  void _setupSessionLevelIceParameters() {
    if (_iceParameters.iceLite) {
      _addAttribute('ice-lite');
    }

    _addAttribute('ice-options', 'trickle');
    _addAttribute('ice-ufrag', _iceParameters.usernameFragment);
    _addAttribute('ice-pwd', _iceParameters.password);

    for (final candidate in _iceCandidates) {
      _addAttribute('candidate', _iceCandidateToSdp(candidate));
    }
  }

  void _setupSessionLevelDtlsParameters() {
    if (_dtlsParameters.fingerprints != null && _dtlsParameters.fingerprints!.isNotEmpty) {
      final fingerprint = _dtlsParameters.fingerprints!.first;
      _addAttribute('fingerprint', '${fingerprint.algorithm} ${fingerprint.value}');
    }

    String setup;
    switch (_dtlsParameters.role) {
      case DtlsRole.client:
        setup = 'active';
        break;
      case DtlsRole.server:
        setup = 'passive';
        break;
      default:
        setup = 'actpass';
    }
    _addAttribute('setup', setup);
  }

  void _addAttribute(String key, [dynamic value]) {
    _sdpObject['attributes'] ??= [];
    if (value == null) {
      _sdpObject['attributes']!.add({'key': key});
    } else {
      _sdpObject['attributes']!.add({'key': key, 'value': value.toString()});
    }
  }

  String _iceCandidateToSdp(IceCandidate candidate) {
    final components = [
      candidate.foundation?.toString() ?? '',
      candidate.component.toString(),
      candidate.protocol?.value.toUpperCase() ?? 'UDP',
      candidate.priority.toString(),
      candidate.ip,
      candidate.port.toString(),
      'typ',
      candidate.type.value,
    ];

    if (candidate.raddr != null && candidate.rport != null) {
      components.addAll([
        'raddr',
        candidate.raddr!,
        'rport',
        candidate.rport.toString(),
      ]);
    }

    return components.join(' ');
  }

  /// Send method (versatica equivalent)
  void send({
    required Map<String, dynamic> offerMediaObject,
    String? reuseMid,
    required RtpParameters offerRtpParameters,
    required RtpParameters answerRtpParameters,
    Map<String, dynamic>? codecOptions,
    bool extmapAllowMixed = false,
  }) {
    _logger.debug('send() [reuseMid:$reuseMid]');

    final mediaSection = AnswerMediaSection(
      iceParameters: _iceParameters,
      iceCandidates: _iceCandidates,
      dtlsParameters: _dtlsParameters,
      sctpParameters: _sctpParameters,
      offerMediaObject: offerMediaObject,
      offerRtpParameters: offerRtpParameters,
      answerRtpParameters: answerRtpParameters,
      codecOptions: codecOptions,
      extmapAllowMixed: extmapAllowMixed,
    );

    int? mediaSectionIdx;
    if (reuseMid != null && _midToIndex.containsKey(reuseMid)) {
      mediaSectionIdx = _midToIndex[reuseMid];
      _replaceMediaSection(mediaSectionIdx!, mediaSection.mediaObject);
      _midToIndex.remove(reuseMid);
    } else {
      mediaSectionIdx = _addMediaSection(mediaSection.mediaObject);
    }

    final mid = offerMediaObject['mid']?.toString();
    if (mid == null) {
      throw Exception('Offer media object must have an MID');
    }
    _midToIndex[mid] = mediaSectionIdx;
    _firstMid ??= mid;

    _regenerateBundleMids();
  }

  /// Receive method (versatica equivalent)
  void receive({
    required String mid,
    required String kind,
    required RtpParameters offerRtpParameters,
    String? streamId,
    String? trackId,
  }) {
    _logger.debug('receive() [mid:$mid, kind:$kind]');

    final mediaSection = OfferMediaSection(
      iceParameters: _iceParameters,
      iceCandidates: _iceCandidates,
      dtlsParameters: _dtlsParameters,
      kind: kind,
      offerRtpParameters: offerRtpParameters,
      streamId: streamId,
      trackId: trackId,
    );

    final mediaSectionIdx = _addMediaSection(mediaSection.mediaObject);
    _midToIndex[mid] = mediaSectionIdx;
    _firstMid ??= mid;

    _regenerateBundleMids();
  }

  /// Send SCTP association (versatica equivalent)
  void sendSctpAssociation(Map<String, dynamic> offerMediaObject) {
    _logger.debug('sendSctpAssociation()');

    final mediaSection = AnswerMediaSection(
      iceParameters: _iceParameters,
      iceCandidates: _iceCandidates,
      dtlsParameters: _dtlsParameters,
      sctpParameters: _sctpParameters,
      offerMediaObject: offerMediaObject,
      offerRtpParameters: null,
      answerRtpParameters: null,
      codecOptions: null,
      extmapAllowMixed: false,
    );

    final mediaSectionIdx = _addMediaSection(mediaSection.mediaObject);
    final mid = offerMediaObject['mid']?.toString() ?? 'datachannel';
    _midToIndex[mid] = mediaSectionIdx;
    _firstMid ??= mid;

    _regenerateBundleMids();
  }

  /// Receive SCTP association (versatica equivalent)
  void receiveSctpAssociation({Map<String, dynamic>? offerMediaObject}) {
    _logger.debug('receiveSctpAssociation()');

    final mediaSection = OfferMediaSection(
      iceParameters: _iceParameters,
      iceCandidates: _iceCandidates,
      dtlsParameters: _dtlsParameters,
      kind: 'application',
      offerRtpParameters: null,
      streamId: null,
      trackId: null,
      sctpParameters: _sctpParameters,
    );

    final mediaSectionIdx = _addMediaSection(mediaSection.mediaObject);
    _midToIndex['datachannel'] = mediaSectionIdx;
    _firstMid ??= 'datachannel';

    _regenerateBundleMids();
  }

  /// Pause media section (versatica equivalent)
  void pauseMediaSection(String mid) {
    _logger.debug('pauseMediaSection() [mid:$mid]');

    final idx = _midToIndex[mid];
    if (idx == null) {
      _logger.warn('pauseMediaSection() | media section not found for mid:$mid');
      return;
    }

    final mediaSection = _mediaSections[idx];
    mediaSection['direction'] = 'inactive';
    _replaceMediaSection(idx, mediaSection);
  }

  /// Resume sending media section (versatica equivalent)
  void resumeSendingMediaSection(String mid) {
    _logger.debug('resumeSendingMediaSection() [mid:$mid]');

    final idx = _midToIndex[mid];
    if (idx == null) {
      _logger.warn('resumeSendingMediaSection() | media section not found for mid:$mid');
      return;
    }

    final mediaSection = _mediaSections[idx];
    mediaSection['direction'] = 'sendonly';
    _replaceMediaSection(idx, mediaSection);
  }

  /// Resume receiving media section (versatica equivalent)
  void resumeReceivingMediaSection(String mid) {
    _logger.debug('resumeReceivingMediaSection() [mid:$mid]');

    final idx = _midToIndex[mid];
    if (idx == null) {
      _logger.warn('resumeReceivingMediaSection() | media section not found for mid:$mid');
      return;
    }

    final mediaSection = _mediaSections[idx];
    mediaSection['direction'] = 'recvonly';
    _replaceMediaSection(idx, mediaSection);
  }

  /// Mux media section with simulcast (versatica equivalent)
  void muxMediaSectionSimulcast(String mid, List<RtpEncodingParameters> encodings) {
    _logger.debug('muxMediaSectionSimulcast() [mid:$mid, encodings:$encodings]');

    final idx = _midToIndex[mid];
    if (idx == null) {
      _logger.warn('muxMediaSectionSimulcast() | media section not found for mid:$mid');
      return;
    }

    final mediaSection = _mediaSections[idx];

    // Update encodings in SDP
    mediaSection['ssrcs'] = [];
    mediaSection['ssrcGroups'] = [];

    for (var i = 0; i < encodings.length; i++) {
      final encoding = encodings[i];
      final ssrc = encoding.ssrc ?? (1000000 + i);
      
      mediaSection['ssrcs'].add({
        'id': ssrc,
        'attribute': 'cname',
        'value': 'mediasoup-client-flutter', // Default cname
      });
      mediaSection['ssrcs'].add({
        'id': ssrc,
        'attribute': 'msid',
        'value': 'mediasoup-client-flutter',
      });

      if (encoding.rtx != null && encoding.rtx!.ssrc != null) {
        final rtxSsrc = encoding.rtx!.ssrc!;
        mediaSection['ssrcs'].add({
          'id': rtxSsrc,
          'attribute': 'cname',
          'value': 'mediasoup-client-flutter',
        });
        mediaSection['ssrcs'].add({
          'id': rtxSsrc,
          'attribute': 'msid',
          'value': 'mediasoup-client-flutter',
        });
        mediaSection['ssrcGroups'].add({
          'semantics': 'FID',
          'ssrcs': '$ssrc $rtxSsrc',
        });
      }
    }

    if (encodings.length > 1) {
      mediaSection['ssrcGroups'].add({
        'semantics': 'SIM',
        'ssrcs': encodings.map((e) => e.ssrc ?? 0).join(' '),
      });
    }

    _replaceMediaSection(idx, mediaSection);
  }

  /// Plan B stop receiving (versatica equivalent)
  void planBStopReceiving({required Map<String, dynamic> offerMediaObject}) {
    _logger.debug('planBStopReceiving()');

    final idx = _mediaSections.indexWhere((s) => s['mid'] == offerMediaObject['mid']);
    if (idx == -1) {
      _logger.warn('planBStopReceiving() | media section not found for mid:${offerMediaObject['mid']}');
      return;
    }

    final mediaSection = InactiveMediaSection(mediaObject: _mediaSections[idx]);
    _replaceMediaSection(idx, mediaSection.mediaObject);
  }

  /// Disable media section (versatica equivalent)
  void disableMediaSection(String mid) {
    _logger.debug('disableMediaSection() [mid:$mid]');

    final idx = _midToIndex[mid];
    if (idx == null) {
      _logger.warn('disableMediaSection() | media section not found for mid:$mid');
      return;
    }

    final mediaSection = InactiveMediaSection(mediaObject: _mediaSections[idx]);
    _replaceMediaSection(idx, mediaSection.mediaObject);
  }

  /// Close media section (versatica equivalent)
  void closeMediaSection(String mid) {
    _logger.debug('closeMediaSection() [mid:$mid]');

    final idx = _midToIndex[mid];
    if (idx == null) {
      _logger.warn('closeMediaSection() | media section not found for mid:$mid');
      return;
    }

    // Remove the media section
    _mediaSections.removeAt(idx);
    _sdpObject['media'].removeAt(idx);
    _midToIndex.remove(mid);

    // Update indices in midToIndex for sections after the removed one
    _midToIndex.forEach((key, value) {
      if (value > idx) {
        _midToIndex[key] = value - 1;
      }
    });

    _regenerateBundleMids();
  }

  /// Get next media section index (versatica equivalent)
  MediaSectionIdx getNextMediaSectionIdx() {
    // If a closed media section is found, return its index.
    for (int idx = 0; idx < _mediaSections.length; ++idx) {
      final mediaSection = _mediaSections[idx];
      if (mediaSection['closed'] == true) {
        return MediaSectionIdx(idx: idx);
      }
    }

    // No closed media sections, return next one.
    return MediaSectionIdx(idx: _mediaSections.length);
  }

  /// Get SDP string (versatica equivalent)
  String getSdp() {
    return write(_sdpObject, null);
  }

  /// Update ICE parameters (versatica equivalent)
  void updateIceParameters(IceParameters iceParameters) {
    _logger.debug('updateIceParameters()');

    // Remove existing ICE attributes
    _removeAttributes(['ice-ufrag', 'ice-pwd', 'ice-lite', 'ice-options', 'candidate']);

    // Add new ICE parameters
    if (iceParameters.iceLite) {
      _addAttribute('ice-lite');
    }

    _addAttribute('ice-options', 'trickle');
    _addAttribute('ice-ufrag', iceParameters.usernameFragment);
    _addAttribute('ice-pwd', iceParameters.password);

    for (final candidate in _iceCandidates) {
      _addAttribute('candidate', _iceCandidateToSdp(candidate));
    }
  }

  /// Update DTLS role (versatica equivalent)
  void updateDtlsRole(DtlsRole role) {
    _logger.debug('updateDtlsRole() [role:$role]');

    String setup;
    switch (role) {
      case DtlsRole.client:
        setup = 'active';
        break;
      case DtlsRole.server:
        setup = 'passive';
        break;
      default:
        setup = 'actpass';
    }

    _removeAttributes(['setup']);
    _addAttribute('setup', setup);
  }

  // ========== PRIVATE METHODS ==========

  void _addAttributeToMedia(Map<String, dynamic> media, String key, [dynamic value]) {
    media['attributes'] ??= [];
    if (value == null) {
      media['attributes']!.add({'key': key});
    } else {
      media['attributes']!.add({'key': key, 'value': value.toString()});
    }
  }

  void _removeAttributes(List<String> keys) {
    _sdpObject['attributes'] ??= [];
    _sdpObject['attributes']!.removeWhere((attr) => keys.contains(attr['key']));
  }

  int _addMediaSection(Map<String, dynamic> mediaSection) {
    final idx = _mediaSections.length;
    _mediaSections.add(mediaSection);
    _sdpObject['media'] ??= [];
    _sdpObject['media']!.add(mediaSection);
    return idx;
  }

  void _replaceMediaSection(int index, Map<String, dynamic> newMediaSection) {
    if (index >= _mediaSections.length) {
      throw Exception('Media section index out of bounds: $index');
    }

    _mediaSections[index] = newMediaSection;
    _sdpObject['media']![index] = newMediaSection;
  }

  void _regenerateBundleMids() {
    // Remove existing BUNDLE group
    _removeAttributes(['group']);

    if (_mediaSections.isEmpty) return;

    // Create new BUNDLE group with all MIDs
    final mids = _mediaSections.map((s) => s['mid']?.toString()).whereType<String>().toList();
    if (mids.isNotEmpty) {
      _addAttribute('group', 'BUNDLE ${mids.join(' ')}');
    }
  }

  @override
  String toString() => 'RemoteSdp(mediaSections: ${_mediaSections.length})';
}