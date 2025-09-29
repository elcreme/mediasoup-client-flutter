import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:mediasoup_client_flutter/src/ortc.dart';
import 'package:mediasoup_client_flutter/src/rtp_parameters.dart';
import 'package:mediasoup_client_flutter/src/sctp_parameters.dart';
import 'package:mediasoup_client_flutter/src/transport.dart';
import 'package:mediasoup_client_flutter/src/common/enhanced_event_emitter.dart';
import 'package:mediasoup_client_flutter/src/common/logger.dart';
import 'package:mediasoup_client_flutter/src/handlers/handler_interface.dart';
import 'package:mediasoup_client_flutter/src/type_conversion.dart';

Logger _logger = Logger('Device');

class Device {
  // Loaded flag.
  bool _loaded = false;
  // Extended RTP capabilities.
  ExtendedRtpCapabilities? _extendedRtpCapabilities;
  // Local RTP capabilities for receiving media.
  RtpCapabilities? _recvRtpCapabilities;
  // Whether we can produce audio/video based on computed extended RTP
  // capabilities.
  CanProduceByKind? _canProduceByKind;
  // Local SCTP capabilities.
  SctpCapabilities? _sctpCapabilities;
  // Observer instance.
  EnhancedEventEmitter _observer = EnhancedEventEmitter();

  // Whether the Device is loaded.
  bool get loaded => _loaded;

  /// RTP capabilities of the Device for receiving media.
  ///
  /// @throws {InvalidStateError} if not loaded.
  RtpCapabilities get rtpCapabilities {
    if (!_loaded) {
      throw ('not loaded');
    }

    return _recvRtpCapabilities!;
  }

  /// SCTP capabilities of the Device.
  /// @throws {InvalidStateError} if not loaded.
  SctpCapabilities get sctpCapabilities {
    if (!_loaded) {
      throw ('not loaded');
    }

    return _sctpCapabilities!;
  }

  /// Observer.
  EnhancedEventEmitter get observer => _observer;

  /// Initialize the Device.
  Future<void> load({
    required RtpCapabilities routerRtpCapabilities,
  }) async {
    _logger.debug(
        'load() [routerRtpCapabilities:${routerRtpCapabilities.toString()}]');

    routerRtpCapabilities = RtpCapabilities.copy(routerRtpCapabilities);

    // Temporal handler to get its capabilities.
    HandlerInterface? handler;

    try {
      if (_loaded) {
        throw ('already loaded');
      }

      // This may throw.
      Ortc.validateRtpCapabilities(routerRtpCapabilities);

      handler = HandlerInterface.handlerFactory();

      RtpCapabilities nativeRtpCapabilities =
          await handler.getNativeRtpCapabilities();

      _logger
          .debug('load() | got native RTP capabilities:$nativeRtpCapabilities');

      // This may throw.
      Ortc.validateRtpCapabilities(nativeRtpCapabilities);

      // Get extended RTP capabilities.
      _extendedRtpCapabilities = Ortc.getExtendedRtpCapabilities(
          nativeRtpCapabilities, routerRtpCapabilities);

      _logger.debug(
          'load() | got extended RTP capabilities:$_extendedRtpCapabilities');

      // Check wether we can produce audio/video.
      _canProduceByKind = CanProduceByKind(
        audio: Ortc.canSend(
            TypeConversion.rtcToMediaKind(RTCRtpMediaType.RTCRtpMediaTypeAudio), 
            _extendedRtpCapabilities!),
        video: Ortc.canSend(
            TypeConversion.rtcToMediaKind(RTCRtpMediaType.RTCRtpMediaTypeVideo), 
            _extendedRtpCapabilities!),
      );

      // Generate our receiving RTP capabilities for receiving media.
      _recvRtpCapabilities =
          Ortc.getRecvRtpCapabilities(_extendedRtpCapabilities!);

      // This may throw.
      if (_recvRtpCapabilities != null) {
        Ortc.validateRtpCapabilities(_recvRtpCapabilities!);
      }

      _logger.debug(
          'load() | got receiving RTP capabilities:$_recvRtpCapabilities');

      // Generate our SCTP capabilities.
      _sctpCapabilities = handler.getNativeSctpCapabilities();

      _logger.debug('load() | got native SCTP capabilities:$_sctpCapabilities');

      _logger.debug('load() successed');

      _loaded = true;

      await handler.close();
    } catch (error) {
      if (handler != null) {
        await handler.close();
      }

      throw error;
    }
  }

  /// Whether we can produce audio/video.
  ///
  /// @throws {InvalidStateError} if not loaded.
  /// @throws {TypeError} if wrong arguments.
  bool canProduce(RTCRtpMediaType kind) {
    if (!_loaded) {
      throw ('not loaded');
    } else if (kind != RTCRtpMediaType.RTCRtpMediaTypeAudio &&
        kind != RTCRtpMediaType.RTCRtpMediaTypeVideo) {
      throw ('invalid kind ${TypeConversion.rtcMediaTypeToString(kind)}');
    }

    return _canProduceByKind!.canIt(kind);
  }

  Transport _createTransport({
    required Direction direction,
    required String id,
    required IceParameters iceParameters,
    required List<IceCandidate> iceCandidates,
    required DtlsParameters dtlsParameters,
    SctpParameters? sctpParameters,
    List<RTCIceServer> iceServers = const <RTCIceServer>[],
    RTCIceTransportPolicy? iceTransportPolicy,
    Map<String, dynamic> additionalSettings = const <String, dynamic>{},
    Map<String, dynamic> proprietaryConstraints = const <String, dynamic>{},
    Map<String, dynamic> appData = const <String, dynamic>{},
    Function? producerCallback,
    Function? consumerCallback,
    Function? dataProducerCallback,
    Function? dataConsumerCallback,
  }) {
    if (!_loaded) {
      throw ('not loaded');
    }

    // Create sending RTP parameters for audio and video
    final audioSendingRtpParameters = Ortc.getSendingRtpParameters(
      TypeConversion.rtcToMediaKind(RTCRtpMediaType.RTCRtpMediaTypeAudio), 
      _extendedRtpCapabilities!,
    );

    final videoSendingRtpParameters = Ortc.getSendingRtpParameters(
      TypeConversion.rtcToMediaKind(RTCRtpMediaType.RTCRtpMediaTypeVideo), 
      _extendedRtpCapabilities!,
    );

    // Create a new Transport.
    Transport transport = Transport(
      direction: direction,
      id: id,
      iceParameters: iceParameters,
      iceCandidates: iceCandidates,
      dtlsParameters: dtlsParameters,
      sctpParameters: sctpParameters,
      iceServers: iceServers,
      iceTransportPolicy: iceTransportPolicy,
      additionalSettings: additionalSettings,
      proprietaryConstraints: proprietaryConstraints,
      appData: appData,
      extendedRtpCapabilities: _extendedRtpCapabilities,
      canProduceByKind: _canProduceByKind!,
      producerCallback: producerCallback,
      dataProducerCallback: dataProducerCallback,
      consumerCallback: consumerCallback,
      dataConsumerCallback: dataConsumerCallback,
    );

    // Emit observer event.
    _observer.safeEmit('newtransport', {
      'transport': transport,
    });

    return transport;
  }

  /// Creates a Transport for sending media.
  ///
  /// @throws {InvalidStateError} if not loaded.
  /// @throws {TypeError} if wrong arguments.
  Transport createSendTransport({
    required String id,
    required IceParameters iceParameters,
    required List<IceCandidate> iceCandidates,
    required DtlsParameters dtlsParameters,
    SctpParameters? sctpParameters,
    List<RTCIceServer> iceServers = const <RTCIceServer>[],
    RTCIceTransportPolicy? iceTransportPolicy,
    Map<String, dynamic> additionalSettings = const <String, dynamic>{},
    Map<String, dynamic> proprietaryConstraints = const <String, dynamic>{},
    Map<String, dynamic> appData = const <String, dynamic>{},
    Function? producerCallback,
    Function? dataProducerCallback,
  }) {
    _logger.debug('createSendTransport()');

    return _createTransport(
      direction: Direction.send,
      id: id,
      iceParameters: iceParameters,
      iceCandidates: iceCandidates,
      dtlsParameters: dtlsParameters,
      sctpParameters: sctpParameters,
      iceServers: iceServers,
      iceTransportPolicy: iceTransportPolicy,
      additionalSettings: additionalSettings,
      proprietaryConstraints: proprietaryConstraints,
      appData: appData,
      producerCallback: producerCallback,
      dataProducerCallback: dataProducerCallback,
    );
  }

  Transport createSendTransportFromMap(
    Map data, {
    Function? producerCallback,
    Function? dataProducerCallback,
  }) {
    return createSendTransport(
      id: data['id'],
      iceParameters: IceParameters.fromMap(data['iceParameters']),
      iceCandidates: List<IceCandidate>.from(data['iceCandidates']
          .map((iceCandidate) => IceCandidate.fromMap(iceCandidate))
          .toList()),
      dtlsParameters: DtlsParameters.fromMap(data['dtlsParameters']),
      sctpParameters: data['sctpParameters'] != null
          ? SctpParameters.fromMap(data['sctpParameters'])
          : null,
      iceServers: [],
      appData: data['appData'] ?? <String, dynamic>{},
      proprietaryConstraints: Map<String, dynamic>.from({
        'optional': [
          {
            'googDscp': true,
          }
        ]
      }),
      additionalSettings: {
        'encodedInsertableStreams': false,
      },
      producerCallback: producerCallback,
      dataProducerCallback: dataProducerCallback,
    );
  }

  /// Creates a Transport for receiving media.
  ///
  /// @throws {InvalidStateError} if not loaded.
  /// @throws {TypeError} if wrong arguments.
  Transport createRecvTransport({
    required String id,
    required IceParameters iceParameters,
    required List<IceCandidate> iceCandidates,
    required DtlsParameters dtlsParameters,
    SctpParameters? sctpParameters,
    List<RTCIceServer> iceServers = const <RTCIceServer>[],
    RTCIceTransportPolicy? iceTransportPolicy,
    Map<String, dynamic> additionalSettings = const <String, dynamic>{},
    Map<String, dynamic> proprietaryConstraints = const <String, dynamic>{},
    Map<String, dynamic> appData = const <String, dynamic>{},
    Function? consumerCallback,
    Function? dataConsumerCallback,
  }) {
    _logger.debug('createRecvTransport()');

    return _createTransport(
      direction: Direction.recv,
      id: id,
      iceParameters: iceParameters,
      iceCandidates: iceCandidates,
      dtlsParameters: dtlsParameters,
      sctpParameters: sctpParameters,
      iceServers: iceServers,
      iceTransportPolicy: iceTransportPolicy,
      additionalSettings: additionalSettings,
      proprietaryConstraints: proprietaryConstraints,
      appData: appData,
      consumerCallback: consumerCallback,
      dataConsumerCallback: dataConsumerCallback,
    );
  }

  Transport createRecvTransportFromMap(
    Map data, {
    Function? consumerCallback,
    Function? dataConsumerCallback,
  }) {
    return createRecvTransport(
      id: data['id'],
      iceParameters: IceParameters.fromMap(data['iceParameters']),
      iceCandidates: List<IceCandidate>.from(data['iceCandidates']
          .map((iceCandidate) => IceCandidate.fromMap(iceCandidate))
          .toList()),
      dtlsParameters: DtlsParameters.fromMap(data['dtlsParameters']),
      sctpParameters: data['sctpParameters'] != null
          ? SctpParameters.fromMap(data['sctpParameters'])
          : null,
      iceServers: [],
      appData: data['appData'] ?? {},
      proprietaryConstraints: Map<String, dynamic>.from({
        'optional': [
          {
            'googDscp': true,
          }
        ]
      }),
      additionalSettings: {
        'encodedInsertableStreams': false,
      },
      consumerCallback: consumerCallback,
      dataConsumerCallback: dataConsumerCallback,
    );
  }
}