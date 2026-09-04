import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PathHelper - normalize', () {
    test('should remove leading slashes', () {
      expect(PathHelper.normalize('/users/123/data.json'),
          equals('users/123/data.json'));
      expect(PathHelper.normalize('//users/123/data.json'),
          equals('users/123/data.json'));
      expect(PathHelper.normalize('///users/123/data.json'),
          equals('users/123/data.json'));
    });

    test('should remove trailing slashes', () {
      expect(PathHelper.normalize('users/123/data.json/'),
          equals('users/123/data.json'));
      expect(PathHelper.normalize('users/123/data.json//'),
          equals('users/123/data.json'));
    });

    test('should replace multiple slashes with single slash', () {
      expect(PathHelper.normalize('users//123///data.json'),
          equals('users/123/data.json'));
    });

    test('should handle empty string', () {
      expect(PathHelper.normalize(''), equals(''));
    });

    test('should handle single segment', () {
      expect(PathHelper.normalize('data.json'), equals('data.json'));
      expect(PathHelper.normalize('/data.json'), equals('data.json'));
    });
  });

  group('PathHelper - join', () {
    test('should join multiple segments', () {
      expect(PathHelper.join(['users', '123', 'data.json']),
          equals('users/123/data.json'));
    });

    test('should normalize joined path', () {
      expect(PathHelper.join(['users/', '/123/', '/data.json']),
          equals('users/123/data.json'));
      expect(PathHelper.join(['//users', '123//', 'data.json']),
          equals('users/123/data.json'));
    });

    test('should handle empty list', () {
      expect(PathHelper.join([]), equals(''));
    });

    test('should handle single segment', () {
      expect(PathHelper.join(['data.json']), equals('data.json'));
    });
  });

  group('PathHelper - dirname', () {
    test('should return parent directory', () {
      expect(PathHelper.dirname('users/123/data.json'), equals('users/123'));
      expect(PathHelper.dirname('users/123/'), equals('users'));
      expect(PathHelper.dirname('a/b/c/d'), equals('a/b/c'));
    });

    test('should return empty string for single segment', () {
      expect(PathHelper.dirname('data.json'), equals(''));
      expect(PathHelper.dirname('/data.json'), equals(''));
    });

    test('should handle empty string', () {
      expect(PathHelper.dirname(''), equals(''));
    });
  });

  group('PathHelper - basename', () {
    test('should return filename', () {
      expect(PathHelper.basename('users/123/data.json'), equals('data.json'));
      expect(PathHelper.basename('/users/123/data.json'), equals('data.json'));
    });

    test('should return path for single segment', () {
      expect(PathHelper.basename('data.json'), equals('data.json'));
    });

    test('should handle empty string', () {
      expect(PathHelper.basename(''), equals(''));
    });

    test('should handle trailing slash', () {
      expect(PathHelper.basename('users/123/'), equals('123'));
    });
  });

  group('PathHelper - extension', () {
    test('should return file extension', () {
      expect(PathHelper.extension('data.json'), equals('.json'));
      expect(PathHelper.extension('users/123/data.json'), equals('.json'));
      expect(PathHelper.extension('archive.tar.gz'), equals('.gz'));
    });

    test('should return empty string for no extension', () {
      expect(PathHelper.extension('noextension'), equals(''));
      expect(PathHelper.extension('users/123/noextension'), equals(''));
    });

    test('should handle dot files', () {
      expect(PathHelper.extension('.gitignore'), equals(''));
      expect(PathHelper.extension('.hidden.txt'), equals('.txt'));
    });

    test('should handle empty string', () {
      expect(PathHelper.extension(''), equals(''));
    });
  });

  group('PathHelper - userPath', () {
    test('should build user-specific path', () {
      expect(PathHelper.userPath('user123', ['ledgers', '456.json']),
          equals('users/user123/ledgers/456.json'));
      expect(PathHelper.userPath('abc', ['data.json']),
          equals('users/abc/data.json'));
    });

    test('should handle empty segments', () {
      expect(PathHelper.userPath('user123', []), equals('users/user123'));
    });

    test('should normalize segments', () {
      expect(PathHelper.userPath('user123', ['/ledgers/', '//456.json']),
          equals('users/user123/ledgers/456.json'));
    });
  });

  group('PathHelper - isAbsolute / makeAbsolute / makeRelative', () {
    test('should check if path is absolute', () {
      expect(PathHelper.isAbsolute('/users/123'), isTrue);
      expect(PathHelper.isAbsolute('users/123'), isFalse);
      expect(PathHelper.isAbsolute(''), isFalse);
    });

    test('should make path absolute', () {
      expect(PathHelper.makeAbsolute('users/123'), equals('/users/123'));
      expect(PathHelper.makeAbsolute('/users/123'), equals('/users/123'));
    });

    test('should make path relative', () {
      expect(PathHelper.makeRelative('/users/123'), equals('users/123'));
      expect(PathHelper.makeRelative('users/123'), equals('users/123'));
    });
  });
}
