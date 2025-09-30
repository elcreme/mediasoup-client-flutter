import 'dart:math';
import 'dart:convert';
import 'package:sdp_transform/sdp_transform.dart';
import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';
import 'package:mediasoup_client_flutter/src/sctp_parameters.dart';
import 'package:mediasoup_client_flutter/src/transport.dart';

/// Base class for media sections in SDP
abstract class MediaSection {
  final Map<String, dynamic> _mediaObject;
  final String mid;
  final String kind;
  final String? cname;
  final bool enableRtx;
  final bool enableSrtp;
  final bool enableSctp;
  final bool enableUdp;
  final bool enableTcp;
  final bool enableRtcpMux;
  final bool isDataChannel;

  Map<String, dynamic> get mediaObject => _mediaObject;
  String get mediaType => kind;
  RtpHeaderDirection get direction;
  bool get isPaused;
  bool get isMuted;
  RtpParameters get rtpParameters;
  Map<String, int> get codecPayloads;
  Map<String, int> get extIds;
  RtpCapabilities get rtpCapabilities;
  bool get offerRtpDtlsRole;

  MediaSection({
    required this.mid,
    required this.kind,
    this.cname,
    this.enableRtx = false,
    this.enableSrtp = false,
    this.enableSctp = false,
    this.enableUdp = true,
    this.enableTcp = false,
    this.enableRtcpMux = true,
    this.isDataChannel = false,
  }) : _mediaObject = {} {
    _mediaObject['mid'] = mid;
    _mediaObject['type'] = kind;
    _mediaObject['protocol'] = enableSctp
        ? 'UDP/DTLS/SCTP'
        : enableSrtp
            ? 'UDP/TLS/RTP/SAVPF'
            : 'RTP/AVP';
    _mediaObject['port'] = 7;
    _mediaObject['connection'] = {'ip': '0.0.0.0', 'version': 4};
    _mediaObject['direction'] = RtpHeaderDirection.inactive.value;

    if (enableRtcpMux) {
      _mediaObject['rtcpMux'] = 'rtcp-mux';
    }

    if (enableSrtp) {
      _mediaObject['crypto'] = [];
    }
  }

  static String getCodecName(String mimeType) {
    return mimeType.split('/')[1].toLowerCase();
  }

  void disable();
  void pause();
  void resume();
  void setRtpParameters(RtpParameters rtpParameters);
  void setRtpMapping(Map<String, dynamic> rtpMapping);
  void setDtlsRole(String role);
  void setDtlsParameters(Map<String, dynamic> dtlsParameters);
  void setSctpParameters(Map<String, dynamic> sctpParameters);
  void setSctpStreamParameters(List<dynamic> sctpStreamParameters);
  void setMaxMessageSize(int maxMessageSize);
  Map<String, dynamic> getObject();
  void close() {
    disable();
    _mediaObject['port'] = 0;
  }

  void setDirection(RtpHeaderDirection direction);

  @override
  String toString() {
    return 'MediaSection(mid: $mid, kind: $kind, direction: $direction)';
  }
}

/// Media section for offers
class OfferMediaSection extends MediaSection {
  @override
  final RtpParameters rtpParameters;
  @override
  final Map<String, int> codecPayloads;
  @override
  final Map<String, int> extIds;
  @override
  final RtpCapabilities rtpCapabilities;
  @override
  RtpHeaderDirection direction;
  @override
  final bool offerRtpDtlsRole;

  OfferMediaSection({
    required IceParameters iceParameters,
    required List<IceCandidate> iceCandidates,
    required DtlsParameters dtlsParameters,
    SctpParameters? sctpParameters,
    required String kind,
    RtpParameters? offerRtpParameters,
    String? streamId,
    String? trackId,
    bool enableRtx = false,
    bool enableSrtp = false,
    bool enableSctp = false,
    bool enableUdp = true,
    bool enableTcp = false,
    bool enableRtcpMux = true,
    bool isDataChannel = false,
  })  : rtpParameters = offerRtpParameters ?? RtpParameters(codecs: [], headerExtensions: [], encodings: [], rtcp: null),
        codecPayloads = offerRtpParameters != null
            ? {for (var codec in offerRtpParameters.codecs) codec.mimeType.toLowerCase(): codec.payloadType}
            : {},
        extIds = offerRtpParameters != null
            ? {for (var ext in offerRtpParameters.headerExtensions) ext.uri: ext.id}
            : {},
        rtpCapabilities = RtpCapabilities(
          codecs: offerRtpParameters?.codecs.cast<RtpCodecCapability>() ?? [],
          headerExtensions: offerRtpParameters?.headerExtensions.cast<RtpHeaderExtension>() ?? [],
        ),
        direction = RtpHeaderDirection.recvonly,
        offerRtpDtlsRole = false,
        super(
          mid: offerRtpParameters?.mid ?? Random().nextInt(1000000).toString(),
          kind: kind,
          cname: offerRtpParameters?.rtcp?.cname,
          enableRtx: enableRtx,
          enableSrtp: enableSrtp,
          enableSctp: enableSctp,
          enableUdp: enableUdp,
          enableTcp: enableTcp,
          enableRtcpMux: enableRtcpMux,
          isDataChannel: isDataChannel,
        ) {
    _mediaObject['iceUfrag'] = iceParameters.usernameFragment;
    _mediaObject['icePwd'] = iceParameters.password;
    _mediaObject['attributes'] = [];
    if (iceParameters.iceLite) {
      _mediaObject['attributes'].add({'key': 'ice-lite'});
    }
    for (var candidate in iceCandidates) {
      _mediaObject['attributes'].add({'key': 'candidate', 'value': _iceCandidateToSdp(candidate)});
    }

    if (dtlsParameters.fingerprints != null && dtlsParameters.fingerprints!.isNotEmpty) {
      final fingerprint = dtlsParameters.fingerprints!.first;
      _mediaObject['attributes'].add({
        'key': 'fingerprint',
        'value': '${fingerprint.algorithm} ${fingerprint.value}',
      });
    }
    _mediaObject['attributes'].add({
      'key': 'setup',
      'value': dtlsParameters.role == DtlsRole.client ? 'active' : 'passive'
    });

    if (kind == 'application' && sctpParameters != null) {
      _mediaObject['protocol'] = 'UDP/DTLS/SCTP';
      _mediaObject['sctp'] = {
        'port': sctpParameters.port,
        'protocol': sctpParameters.protocol ?? 'webrtc-datachannel',
      };
      return;
    }

    if (offerRtpParameters != null) {
      _mediaObject['rtp'] = [];
      _mediaObject['rtcpFb'] = [];
      _mediaObject['fmtp'] = [];
      for (var codec in offerRtpParameters.codecs) {
        _mediaObject['rtp'].add({
          'payload': codec.payloadType,
          'codec': codec.mimeType.split('/')[1].toUpperCase(),
          'rate': codec.clockRate,
          if (codec.channels != null && codec.channels! > 1) 'encoding': codec.channels,
        });
        if (codec.rtcpFeedback != null) {
          for (var fb in codec.rtcpFeedback!) {
            _mediaObject['rtcpFb'].add({
              'payload': codec.payloadType,
              'type': fb.type,
              'subtype': fb.parameter,
            });
          }
        }
      }
      _mediaObject['payloads'] = offerRtpParameters.codecs.map((c) => c.payloadType).join(' ');

      _mediaObject['ext'] = offerRtpParameters.headerExtensions
          .map((ext) => {
                'uri': ext.uri,
                'id': ext.id,
              })
          .toList();

      if (streamId != null && trackId != null) {
        _mediaObject['ssrcs'] = [];
        _mediaObject['ssrcs'].add({
          'id': 1000000,
          'attribute': 'cname',
          'value': offerRtpParameters.rtcp?.cname ?? '',
        });
        _mediaObject['ssrcs'].add({
          'id': 1000000,
          'attribute': 'msid',
          'value': '$streamId $trackId',
        });
      }
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
      components.addAll(['raddr', candidate.raddr!, 'rport', candidate.rport.toString()]);
    }
    return components.join(' ');
  }

  @override
  bool get isPaused => direction == RtpHeaderDirection.inactive;
  @override
  bool get isMuted => direction == RtpHeaderDirection.inactive;

  @override
  void disable() {
    direction = RtpHeaderDirection.inactive;
    _mediaObject['direction'] = direction.value;
  }

  @override
  void pause() {
    if (direction == RtpHeaderDirection.sendrecv) {
      direction = RtpHeaderDirection.recvonly;
    } else if (direction == RtpHeaderDirection.sendonly) {
      direction = RtpHeaderDirection.inactive;
    }
    _mediaObject['direction'] = direction.value;
  }

  @override
  void resume() {
    if (direction == RtpHeaderDirection.recvonly) {
      direction = RtpHeaderDirection.sendrecv;
    } else if (direction == RtpHeaderDirection.inactive) {
      direction = RtpHeaderDirection.sendonly;
    }
    _mediaObject['direction'] = direction.value;
  }

  @override
  void setRtpParameters(RtpParameters rtpParameters) {}

  @override
  void setRtpMapping(Map<String, dynamic> rtpMapping) {}

  @override
  void setDtlsRole(String role) {
    _mediaObject['attributes'] ??= [];
    _mediaObject['attributes'].removeWhere((attr) => attr['key'] == 'setup');
    _mediaObject['attributes'].add({'key': 'setup', 'value': role == 'client' ? 'active' : 'passive'});
  }

  @override
  void setDtlsParameters(Map<String, dynamic> dtlsParameters) {
    _mediaObject['attributes'] ??= [];
    _mediaObject['attributes'].removeWhere((attr) => attr['key'] == 'fingerprint');
    if (dtlsParameters['fingerprints'] != null && dtlsParameters['fingerprints'].isNotEmpty) {
      final fingerprint = dtlsParameters['fingerprints'].first;
      _mediaObject['attributes'].add({
        'key': 'fingerprint',
        'value': '${fingerprint.algorithm} ${fingerprint.value}',
      });
    }
    _mediaObject['attributes'].removeWhere((attr) => attr['key'] == 'setup');
    _mediaObject['attributes'].add({
      'key': 'setup',
      'value': dtlsParameters['role'] == 'client' ? 'active' : 'passive'
    });
  }

  @override
  void setSctpParameters(Map<String, dynamic> sctpParameters) {
    _mediaObject['sctp'] = {
      'port': sctpParameters['port'],
      'protocol': sctpParameters['protocol'] ?? 'webrtc-datachannel',
      'streams': sctpParameters['streams'] ?? 65535,
    };
  }

  @override
  void setSctpStreamParameters(List<dynamic> sctpStreamParameters) {}

  @override
  void setMaxMessageSize(int maxMessageSize) {
    _mediaObject['maxMessageSize'] = maxMessageSize;
  }

  @override
  Map<String, dynamic> getObject() {
    return {
      'mid': mid,
      'kind': kind,
      'rtpParameters': rtpParameters.toMap(),
      'rtpCapabilities': rtpCapabilities.toMap(),
      'direction': direction.toString().split('.').last,
      'offerRtpDtlsRole': offerRtpDtlsRole,
      'cname': cname,
      'enableRtx': enableRtx,
      'enableSrtp': enableSrtp,
      'enableSctp': enableSctp,
      'enableUdp': enableUdp,
      'enableTcp': enableTcp,
      'enableRtcpMux': enableRtcpMux,
      'isDataChannel': isDataChannel,
    };
  }

  @override
  void setDirection(RtpHeaderDirection direction) {
    this.direction = direction;
    _mediaObject['direction'] = direction.value;
  }
}

/// Media section for answers
class AnswerMediaSection extends MediaSection {
  @override
  final RtpParameters rtpParameters;
  @override
  final Map<String, int> codecPayloads;
  @override
  final Map<String, int> extIds;
  @override
  final RtpCapabilities rtpCapabilities;
  @override
  RtpHeaderDirection direction;
  @override
  final bool offerRtpDtlsRole;

  AnswerMediaSection({
    required IceParameters iceParameters,
    required List<IceCandidate> iceCandidates,
    required DtlsParameters dtlsParameters,
    SctpParameters? sctpParameters,
    required Map<String, dynamic> offerMediaObject,
    RtpParameters? offerRtpParameters,
    RtpParameters? answerRtpParameters,
    Map<String, dynamic>? codecOptions,
    bool extmapAllowMixed = false,
  })  : rtpParameters = answerRtpParameters ?? RtpParameters(codecs: [], headerExtensions: [], encodings: [], rtcp: null),
        codecPayloads = answerRtpParameters != null
            ? {for (var codec in answerRtpParameters.codecs) codec.mimeType.toLowerCase(): codec.payloadType}
            : {},
        extIds = answerRtpParameters != null
            ? {for (var ext in answerRtpParameters.headerExtensions) ext.uri: ext.id}
            : {},
        rtpCapabilities = RtpCapabilities(
          codecs: answerRtpParameters?.codecs.cast<RtpCodecCapability>() ?? [],
          headerExtensions: answerRtpParameters?.headerExtensions.cast<RtpHeaderExtension>() ?? [],
        ),
        direction = RtpHeaderDirection.sendonly,
        offerRtpDtlsRole = false,
        super(
          mid: offerMediaObject['mid']?.toString() ?? '',
          kind: offerMediaObject['type'] ?? '',
          cname: answerRtpParameters?.rtcp?.cname,
          enableRtx: offerMediaObject['rtx'] != null,
          enableSrtp: offerMediaObject['protocol'] == 'UDP/TLS/RTP/SAVPF',
          enableSctp: offerMediaObject['protocol'] == 'UDP/DTLS/SCTP',
          enableUdp: true,
          enableTcp: false,
          enableRtcpMux: offerMediaObject['rtcpMux'] == 'rtcp-mux',
          isDataChannel: offerMediaObject['type'] == 'application',
        ) {
    _mediaObject.addAll(Map<String, dynamic>.from(offerMediaObject));
    _mediaObject['direction'] = direction.value;

    _mediaObject['iceUfrag'] = iceParameters.usernameFragment;
    _mediaObject['icePwd'] = iceParameters.password;
    _mediaObject['attributes'] ??= [];
    if (iceParameters.iceLite) {
      _mediaObject['attributes'].add({'key': 'ice-lite'});
    }
    for (var candidate in iceCandidates) {
      _mediaObject['attributes'].add({'key': 'candidate', 'value': _iceCandidateToSdp(candidate)});
    }

    if (dtlsParameters.fingerprints != null && dtlsParameters.fingerprints!.isNotEmpty) {
      final fingerprint = dtlsParameters.fingerprints!.first;
      _mediaObject['attributes'].add({
        'key': 'fingerprint',
        'value': '${fingerprint.algorithm} ${fingerprint.value}',
      });
    }
    _mediaObject['attributes'].add({
      'key': 'setup',
      'value': dtlsParameters.role == DtlsRole.client ? 'passive' : 'active'
    });

    if (_mediaObject['type'] == 'application' && sctpParameters != null) {
      _mediaObject['protocol'] = 'UDP/DTLS/SCTP';
      _mediaObject['sctp'] = {
        'port': sctpParameters.port,
        'protocol': sctpParameters.protocol ?? 'webrtc-datachannel',
      };
      return;
    }

    if (offerRtpParameters != null && answerRtpParameters != null) {
      _mediaObject['rtp'] = [];
      _mediaObject['fmtp'] = [];
      _mediaObject['rtcpFb'] = [];

      for (var codec in answerRtpParameters.codecs) {
        _mediaObject['rtp'].add({
          'payload': codec.payloadType,
          'codec': codec.mimeType.split('/')[1].toUpperCase(),
          'rate': codec.clockRate,
          if (codec.channels != null && codec.channels! > 1) 'encoding': codec.channels,
        });
        if (codec.rtcpFeedback != null) {
          for (var fb in codec.rtcpFeedback!) {
            _mediaObject['rtcpFb'].add({
              'payload': codec.payloadType,
              'type': fb.type,
              'subtype': fb.parameter,
            });
          }
        }
      }
      _mediaObject['payloads'] = answerRtpParameters.codecs.map((c) => c.payloadType).join(' ');

      if (codecOptions != null) {
        for (var entry in codecOptions.entries) {
          _mediaObject['fmtp'].add({
            'payload': answerRtpParameters.codecs
                .firstWhere((c) => c.mimeType.toLowerCase().contains(entry.key.toLowerCase()))
                .payloadType,
            'config': '${entry.key}=${entry.value}',
          });
        }
      }

      _mediaObject['ext'] = answerRtpParameters.headerExtensions
          .map((ext) => {
                'uri': ext.uri,
                'id': ext.id,
              })
          .toList();
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
      components.addAll(['raddr', candidate.raddr!, 'rport', candidate.rport.toString()]);
    }
    return components.join(' ');
  }

  @override
  bool get isPaused => direction == RtpHeaderDirection.inactive;
  @override
  bool get isMuted => direction == RtpHeaderDirection.inactive;

  @override
  void disable() {
    direction = RtpHeaderDirection.inactive;
    _mediaObject['direction'] = direction.value;
  }

  @override
  void pause() {
    if (direction == RtpHeaderDirection.sendrecv) {
      direction = RtpHeaderDirection.recvonly;
    } else if (direction == RtpHeaderDirection.sendonly) {
      direction = RtpHeaderDirection.inactive;
    }
    _mediaObject['direction'] = direction.value;
  }

  @override
  void resume() {
    if (direction == RtpHeaderDirection.recvonly) {
      direction = RtpHeaderDirection.sendrecv;
    } else if (direction == RtpHeaderDirection.inactive) {
      direction = RtpHeaderDirection.sendonly;
    }
    _mediaObject['direction'] = direction.value;
  }

  @override
  void setRtpParameters(RtpParameters rtpParameters) {}

  @override
  void setRtpMapping(Map<String, dynamic> rtpMapping) {}

  @override
  void setDtlsRole(String role) {
    _mediaObject['attributes'] ??= [];
    _mediaObject['attributes'].removeWhere((attr) => attr['key'] == 'setup');
    _mediaObject['attributes'].add({'key': 'setup', 'value': role == 'client' ? 'active' : 'passive'});
  }

  @override
  void setDtlsParameters(Map<String, dynamic> dtlsParameters) {
    _mediaObject['attributes'] ??= [];
    _mediaObject['attributes'].removeWhere((attr) => attr['key'] == 'fingerprint');
    if (dtlsParameters['fingerprints'] != null && dtlsParameters['fingerprints'].isNotEmpty) {
      final fingerprint = dtlsParameters['fingerprints'].first;
      _mediaObject['attributes'].add({
        'key': 'fingerprint',
        'value': '${fingerprint.algorithm} ${fingerprint.value}',
      });
    }
    _mediaObject['attributes'].removeWhere((attr) => attr['key'] == 'setup');
    _mediaObject['attributes'].add({
      'key': 'setup',
      'value': dtlsParameters['role'] == 'client' ? 'passive' : 'active'
    });
  }

  @override
  void setSctpParameters(Map<String, dynamic> sctpParameters) {
    _mediaObject['sctp'] = {
      'port': sctpParameters['port'],
      'protocol': sctpParameters['protocol'] ?? 'webrtc-datachannel',
      'streams': sctpParameters['streams'] ?? 65535,
    };
  }

  @override
  void setSctpStreamParameters(List<dynamic> sctpStreamParameters) {}

  @override
  void setMaxMessageSize(int maxMessageSize) {
    _mediaObject['maxMessageSize'] = maxMessageSize;
  }

  @override
  Map<String, dynamic> getObject() {
    return {
      'mid': mid,
      'kind': kind,
      'rtpParameters': rtpParameters.toMap(),
      'rtpCapabilities': rtpCapabilities.toMap(),
      'direction': direction.toString().split('.').last,
      'offerRtpDtlsRole': offerRtpDtlsRole,
      'cname': cname,
      'enableRtx': enableRtx,
      'enableSrtp': enableSrtp,
      'enableSctp': enableSctp,
      'enableUdp': enableUdp,
      'enableTcp': enableTcp,
      'enableRtcpMux': enableRtcpMux,
      'isDataChannel': isDataChannel,
    };
  }

  @override
  void setDirection(RtpHeaderDirection direction) {
    this.direction = direction;
    _mediaObject['direction'] = direction.value;
  }
}

/// Media section for inactive state
class InactiveMediaSection extends MediaSection {
  InactiveMediaSection({
    required Map<String, dynamic> mediaObject,
  }) : super(
          mid: mediaObject['mid']?.toString() ?? '',
          kind: mediaObject['type'] ?? '',
          cname: null,
          enableRtx: false,
          enableSrtp: mediaObject['protocol'] == 'UDP/TLS/RTP/SAVPF',
          enableSctp: mediaObject['protocol'] == 'UDP/DTLS/SCTP',
          enableUdp: true,
          enableTcp: false,
          enableRtcpMux: mediaObject['rtcpMux'] == 'rtcp-mux',
          isDataChannel: mediaObject['type'] == 'application',
        ) {
    _mediaObject.addAll(Map<String, dynamic>.from(mediaObject));
    _mediaObject['direction'] = RtpHeaderDirection.inactive.value;
    _mediaObject['port'] = 0;
  }

  @override
  RtpParameters get rtpParameters => RtpParameters(codecs: [], headerExtensions: [], encodings: [], rtcp: null);
  @override
  Map<String, int> get codecPayloads => {};
  @override
  Map<String, int> get extIds => {};
  @override
  RtpCapabilities get rtpCapabilities => RtpCapabilities(codecs: [], headerExtensions: []);
  @override
  RtpHeaderDirection get direction => RtpHeaderDirection.inactive;
  @override
  bool get offerRtpDtlsRole => false;
  @override
  bool get isPaused => true;
  @override
  bool get isMuted => true;

  @override
  void disable() {
    _mediaObject['direction'] = RtpHeaderDirection.inactive.value;
  }

  @override
  void pause() {
    _mediaObject['direction'] = RtpHeaderDirection.inactive.value;
  }

  @override
  void resume() {}

  @override
  void setRtpParameters(RtpParameters rtpParameters) {}

  @override
  void setRtpMapping(Map<String, dynamic> rtpMapping) {}

  @override
  void setDtlsRole(String role) {
    _mediaObject['attributes'] ??= [];
    _mediaObject['attributes'].removeWhere((attr) => attr['key'] == 'setup');
    _mediaObject['attributes'].add({'key': 'setup', 'value': role == 'client' ? 'active' : 'passive'});
  }

  @override
  void setDtlsParameters(Map<String, dynamic> dtlsParameters) {
    _mediaObject['attributes'] ??= [];
    _mediaObject['attributes'].removeWhere((attr) => attr['key'] == 'fingerprint');
    if (dtlsParameters['fingerprints'] != null && dtlsParameters['fingerprints'].isNotEmpty) {
      final fingerprint = dtlsParameters['fingerprints'].first;
      _mediaObject['attributes'].add({
        'key': 'fingerprint',
        'value': '${fingerprint.algorithm} ${fingerprint.value}',
      });
    }
    _mediaObject['attributes'].removeWhere((attr) => attr['key'] == 'setup');
    _mediaObject['attributes'].add({
      'key': 'setup',
      'value': dtlsParameters['role'] == 'client' ? 'passive' : 'active'
    });
  }

  @override
  void setSctpParameters(Map<String, dynamic> sctpParameters) {
    _mediaObject['sctp'] = {
      'port': sctpParameters['port'],
      'protocol': sctpParameters['protocol'] ?? 'webrtc-datachannel',
      'streams': sctpParameters['streams'] ?? 65535,
    };
  }

  @override
  void setSctpStreamParameters(List<dynamic> sctpStreamParameters) {}

  @override
  void setMaxMessageSize(int maxMessageSize) {
    _mediaObject['maxMessageSize'] = maxMessageSize;
  }

  @override
  Map<String, dynamic> getObject() {
    return {
      'mid': mid,
      'kind': kind,
      'rtpParameters': rtpParameters.toMap(),
      'rtpCapabilities': rtpCapabilities.toMap(),
      'direction': direction.toString().split('.').last,
      'offerRtpDtlsRole': offerRtpDtlsRole,
      'cname': cname,
      'enableRtx': enableRtx,
      'enableSrtp': enableSrtp,
      'enableSctp': enableSctp,
      'enableUdp': enableUdp,
      'enableTcp': enableTcp,
      'enableRtcpMux': enableRtcpMux,
      'isDataChannel': isDataChannel,
    };
  }

  @override
  void setDirection(RtpHeaderDirection direction) {
    this._mediaObject['direction'] = RtpHeaderDirection.inactive.value;
  }
}