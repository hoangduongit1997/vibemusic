import 'dart:developer';
import 'dart:io';
import 'dart:typed_data';

import 'package:al_downloader/al_downloader.dart';
import 'package:audio_service/audio_service.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:get_it/get_it.dart';
import 'package:gyawun/utils/playback_cache.dart';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart';
import 'package:metadata_god/metadata_god.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

YoutubeExplode yt = YoutubeExplode();
download(MediaItem song) async {
  String? item = Hive.box('downloads').get(song.id);
  if (item != null) {
    return;
  }
  bool status = await checkAndRequestPermissions();
  if (!status) return;
  final RegExp avoid = RegExp(r'[\.\\\*\:\"\?#/;\|]');
  String oldName = song.title.replaceAll(avoid, "");

  int count = 1;
  String name = oldName;
  while (await File('/storage/emulated/0/Music/$name.m4a').exists()) {
    name = '$oldName($count)';
    count++;
  }
  if (song.extras!['provider'] == 'youtube') {
    await downloadYoutubeSong(song, '/storage/emulated/0/Music/$name.m4a');
  } else {
    int downloadQuality =
        Hive.box('settings').get('downloadQuality', defaultValue: 160);
    String url = song.extras!['url']
        .toString()
        .replaceAll(RegExp('_92|_160|_320'), '_$downloadQuality');
    ALDownloader.download(
      url,
      directoryPath: '/storage/emulated/0/Music/',
      fileName: '$name.m4a',
      downloaderHandlerInterface: ALDownloaderHandlerInterface(
        progressHandler: (progress) {
          Hive.box('downloads').put(song.id,
              {'path': null, 'progress': progress, 'status': 'pending'});
        },
        succeededHandler: () async {
          File file = File('/storage/emulated/0/Music/$name.m4a');
          Response res = await get(song.artUri!);
          await saveImage(song.id, res.bodyBytes);
          if (song.extras!['provider'] != 'youtube') {
            await MetadataGod.writeMetadata(
              file: file.path,
              metadata: Metadata(
                title: oldName,
                artist: song.artist,
                album: song.album,
                genre: song.genre,
                trackNumber: 1,
                year: int.parse(song.extras?['year'] ?? 0),
                fileSize: file.lengthSync(),
                picture: Picture(
                  data: res.bodyBytes,
                  mimeType: 'image/jpeg',
                ),
              ),
            );
          }

          Hive.box('downloads').put(song.id, {
            'path': file.path,
            'progress': 100,
            'status': 'done',
            ...song.extras ?? {}
          });
        },
        failedHandler: () {
          Hive.box('downloads').delete(song.id);
        },
      ),
    );
  }
}

Future<bool> checkAndRequestPermissions() async {
  if (await Permission.audio.status.isDenied &&
      await Permission.storage.status.isDenied) {
    await [Permission.audio, Permission.storage].request();

    if (await Permission.audio.status.isDenied &&
        await Permission.storage.status.isDenied) {
      await openAppSettings();
    }
  }
  if (Platform.isAndroid) {
    AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;

    if (await Permission.manageExternalStorage.isDenied &&
        info.version.sdkInt == 29) {
      await Permission.manageExternalStorage.request();
    }
  }

  return await Permission.storage.isGranted || await Permission.audio.isGranted;
}

Future<MediaItem> processSong(Map song) async {
  Map? downloaded = Hive.box('downloads').get(song['id']);
  MediaItem mediaItem;
  if (downloaded != null &&
      downloaded['status'] == 'done' &&
      await File(downloaded['path']).exists()) {
    Uri image = await getImageUri(song['id']);

    mediaItem = MediaItem(
      id: downloaded['id'],
      title: downloaded['title'],
      album: downloaded['album'],
      artUri: image,
      artist: downloaded['artist'],
      extras: {
        'id': downloaded['id'],
        'url': downloaded['path'],
        'offline': true,
        'image': image.path,
        'artist': downloaded['artist'],
        'album': downloaded['album'],
        'title': downloaded['title'],
      },
    );
  } else {
    if (song['provider'] != 'youtube') {
      int streamingQuality =
          Hive.box('settings').get('streamingQuality', defaultValue: 160);
      song['url'] =
          song['url'].toString().replaceAll('_96', '_$streamingQuality');
    }
    String? cacheFile =
        await GetIt.I<PlaybackCache>().getFile(url: song['url']);
    if (cacheFile != null) {
      song['url'] = cacheFile;
      song['offline'] = true;
      mediaItem = MediaItem(
        id: song['id'],
        title: song['title'],
        album: song['album'],
        artUri: Uri.parse(song['image']),
        artist: song['artist'],
        extras: Map.from(song),
      );
    } else {
      mediaItem = MediaItem(
        id: song['id'],
        title: song['title'],
        album: song['album'],
        artUri: Uri.parse(song['image']),
        artist: song['artist'],
        extras: Map.from(song),
      );
    }
  }

  return mediaItem;
}

Future<void> deleteSong({dynamic key, String path = ""}) async {
  File file = File(path);
  if (await file.exists()) {
    await file.delete();
  }
  Hive.box('downloads').delete(key);
  file = File('${(await getApplicationDocumentsDirectory()).path}/$key.jpg');
  if (await file.exists()) {
    await file.delete();
  }
}

Future<Uri> getImageUri(String id) async {
  final tempDir = await getApplicationDocumentsDirectory();
  final file = File('${tempDir.path}/$id.jpg');

  return file.uri;
}

Future<void> saveImage(String id, Uint8List bytes) async {
  final tempDir = await getApplicationDocumentsDirectory();
  final file = File('${tempDir.path}/$id.jpg');
  try {
    await file.writeAsBytes(bytes);
  } catch (err) {
    log(err.toString());
  }
}

Future<String> getSongUrl(
  String id,
) async {
  String quality = Hive.box('settings')
      .get('youtubeStreamingQuality', defaultValue: 'Medium');

  id = id.replaceFirst('youtube', '');
  return 'http://${InternetAddress.loopbackIPv4.host}:8080?id=$id&q=$quality';
}

Future<void> downloadYoutubeSong(MediaItem song, String path) async {
  Hive.box('downloads').put(song.id, {
    'path': null,
    'progress': 0.0,
    'status': 'pending',
    ...song.extras ?? {}
  });
  String id = song.id.replaceFirst('youtube', '');
  StreamManifest manifest = await yt.videos.streamsClient.getManifest(id);
  int qualityIndex = 0;
  List<AudioOnlyStreamInfo> streamInfos =
      manifest.audioOnly.sortByBitrate().reversed.toList();
  String quality = (Hive.box('settings')
          .get('youtubeDownloadQuality', defaultValue: 'Medium'))
      .toString()
      .toLowerCase();
  if (quality == 'low') {
    qualityIndex = 0;
  } else if (quality == 'medium') {
    qualityIndex = (streamInfos.length / 2).floor();
  } else {
    qualityIndex = streamInfos.length - 1;
  }
  AudioOnlyStreamInfo streamInfo = streamInfos[qualityIndex];
  Stream<List<int>> stream = yt.videos.streamsClient.get(streamInfo);
  var file = await File(path).create();

  Response res = await get(song.artUri!);
  await saveImage(song.id, res.bodyBytes);
  int total = streamInfo.size.totalBytes;
  List<int> recieved = [];
  stream.listen((element) async {
    recieved += element;
    if (recieved.length == total) {
      await file.writeAsBytes(recieved);
    }
    Hive.box('downloads').put(song.id, {
      'path': file.path,
      'progress': (recieved.length / total) * 100,
      'status': recieved.length == total ? 'done' : 'pending',
      ...song.extras ?? {}
    });
  }).onDone(() {
    Hive.box('downloads').put(song.id, {
      'path': file.path,
      'progress': 100,
      'status': 'done',
      ...song.extras ?? {}
    });
  });

  // Pipe all the content of the stream into the file.
  try {} catch (err) {
    Hive.box('downloads').delete(song.id);
  }
}
