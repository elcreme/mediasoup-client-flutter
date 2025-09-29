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
  
    // Use raddr and rport instead of relatedAddress/relatedPort
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

    final mid = offerMediaObject['mid']?.toString();
    if (mid == null) {
      throw Exception('Offer media object must have an MID');
    }

    int mediaSectionIdx;
    if (reuseMid != null && _midToIndex.containsKey(reuseMid)) {
      // Reuse existing media section
      mediaSectionIdx = _midToIndex[reuseMid]!;
      _replaceMediaSection(mediaSectionIdx, offerMediaObject);
      _midToIndex.remove(reuseMid);
    } else {
      // Add new media section
      mediaSectionIdx = _addMediaSection(offerMediaObject);
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

    final mediaSection = {
      'mid': mid,
      'type': kind,
      'port': 9,
      'protocol': 'UDP/TLS/RTP/SAVPF',
      'direction': 'recvonly',
      'rtp': [],
      'fmtp': [],
      'rtcpFb': [],
      'ext': [],
      'ssrcs': [],
      'ssrcGroups': [],
      'attributes': [],
    };

    // Add codecs from offer parameters
    for (final codec in offerRtpParameters.codecs) {
      (mediaSection['rtp'] as List).add({
        'payload': codec.payloadType,
        'codec': codec.mimeType.split('/')[1].toUpperCase(),
        'rate': codec.clockRate,
        if (codec.channels != null && codec.channels! > 1) 'encoding': codec.channels,
      });
    }

    final mediaSectionIdx = _addMediaSection(mediaSection);
    _midToIndex[mid] = mediaSectionIdx;
    _firstMid ??= mid;

    _regenerateBundleMids();
  }

  /// Receive SCTP association (versatica equivalent)
  void receiveSctpAssociation({Map<String, dynamic>? sctpParameters}) {
    _logger.debug('receiveSctpAssociation()');

    const mid = 'datachannel';
    const kind = 'application';

    final mediaSection = {
      'mid': mid,
      'type': kind,
      'port': 5000,
      'protocol': 'UDP/DTLS/SCTP',
      'direction': 'sendrecv',
      'sctp': {
        'port': sctpParameters?['port'] ?? 5000,
        'protocol': sctpParameters?['protocol'] ?? 'webrtc-datachannel',
      },
      'attributes': [],
    };

    final mediaSectionIdx = _addMediaSection(mediaSection);
    _midToIndex[mid] = mediaSectionIdx;
    _firstMid ??= mid;

    _regenerateBundleMids();
  }

  void sendSctpAssociation(Map<String, dynamic> offerMediaObject) {
    _logger.debug('sendSctpAssociation()');

    const mid = 'datachannel';
    const kind = 'application';

    // Create media section based on offer
    final mediaSection = {
      'mid': mid,
      'type': kind,
      'port': offerMediaObject['port'] ?? 5000,
      'protocol': offerMediaObject['protocol'] ?? 'UDP/DTLS/SCTP',
      'direction': 'sendrecv',
      'sctp': offerMediaObject['sctp'],
      'attributes': [],
    };

    final mediaSectionIdx = _addMediaSection(mediaSection);
    _midToIndex[mid] = mediaSectionIdx;
    _firstMid ??= mid;

    _regenerateBundleMids();
  }

  /// Disable media section (versatica equivalent)
  void disableMediaSection(String mid) {
    _logger.debug('disableMediaSection() [mid:$mid]');

    final mediaSectionIdx = _midToIndex[mid];
    if (mediaSectionIdx == null) {
      _logger.warn('disableMediaSection() | media section not found for mid:$mid');
      return;
    }

    final mediaSection = _mediaSections[mediaSectionIdx];
    mediaSection['direction'] = 'inactive';

    _regenerateBundleMids();
  }

  /// Close media section (versatica equivalent)
  void closeMediaSection(String mid) {
    _logger.debug('closeMediaSection() [mid:$mid]');

    final mediaSectionIdx = _midToIndex[mid];
    if (mediaSectionIdx == null) {
      _logger.warn('closeMediaSection() | media section not found for mid:$mid');
      return;
    }

    // Remove from media sections list
    _mediaSections.removeAt(mediaSectionIdx);
    _midToIndex.remove(mid);

    // Update indices in midToIndex map
    _midToIndex.forEach((existingMid, idx) {
      if (idx > mediaSectionIdx) {
        _midToIndex[existingMid] = idx - 1;
      }
    });

    // Remove from SDP media list
    _sdpObject['media']!.removeAt(mediaSectionIdx);

    _regenerateBundleMids();
  }

  /// Get next media section index (versatica equivalent)
  MediaSectionIdx getNextMediaSectionIdx() {
    if (_planB) {
      // In planB, reuse first media section
      return MediaSectionIdx(idx: 0);
    }

    // In unified plan, add new media section
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
    _sdpObject['attributes']!.removeWhere((attr) => keys.contains(attr['key']));
  }

  int _addMediaSection(Map<String, dynamic> mediaSection) {
    final idx = _mediaSections.length;
    _mediaSections.add(mediaSection);
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