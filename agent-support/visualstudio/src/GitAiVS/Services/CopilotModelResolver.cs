using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;

namespace GitAiVS.Services
{
    /// <summary>
    /// Resolves the model Copilot Chat used, from the chat session files Visual Studio
    /// writes under <c>&lt;solution dir&gt;\.vs\&lt;solution&gt;\copilot-chat\&lt;hash&gt;\sessions\&lt;id&gt;</c>.
    ///
    /// A session file is a 1-byte header followed by consecutive MessagePack values:
    /// a session header map, then one <c>[role, message]</c> array per chat message.
    /// User messages (role 0) carry <c>Model = { ModelId }</c> (may be "auto");
    /// assistant messages (role 1) carry <c>Model = [tag, { Id }]</c> with the concrete model.
    /// </summary>
    internal static class CopilotModelResolver
    {
        public const string Unknown = "unknown";

        private static readonly object CacheLock = new();
        private static string? _cachedPath;
        private static DateTime _cachedWriteTime;
        private static long _cachedLength;
        private static string? _cachedModel;

        /// <summary>
        /// Returns the model of the most recently written Copilot Chat session that is
        /// visible from <paramref name="filePath"/> (searching <c>.vs</c> folders from the
        /// file's directory up to <paramref name="repoRoot"/>), or "unknown". Never throws.
        /// </summary>
        public static string Resolve(string repoRoot, string? filePath)
        {
            try
            {
                var session = FindLatestSessionFile(repoRoot, filePath);
                if (session == null)
                    return Unknown;

                lock (CacheLock)
                {
                    if (_cachedPath == session.FullName
                        && _cachedWriteTime == session.LastWriteTimeUtc
                        && _cachedLength == session.Length)
                    {
                        return _cachedModel ?? Unknown;
                    }
                }

                byte[] bytes;
                using (var stream = new FileStream(session.FullName, FileMode.Open, FileAccess.Read,
                           FileShare.ReadWrite | FileShare.Delete))
                using (var memory = new MemoryStream())
                {
                    stream.CopyTo(memory);
                    bytes = memory.ToArray();
                }

                var model = ExtractModel(bytes);
                lock (CacheLock)
                {
                    _cachedPath = session.FullName;
                    _cachedWriteTime = session.LastWriteTimeUtc;
                    _cachedLength = session.Length;
                    _cachedModel = model;
                }

                Trace.WriteLine($"[git-ai] Copilot model from {session.Name}: {model ?? Unknown}");
                return model ?? Unknown;
            }
            catch (Exception ex)
            {
                Trace.WriteLine($"[git-ai] Copilot model resolution failed: {ex.Message}");
                return Unknown;
            }
        }

        internal static FileInfo? FindLatestSessionFile(string repoRoot, string? filePath)
        {
            FileInfo? latest = null;
            foreach (var vsDir in CandidateVsDirs(repoRoot, filePath))
            {
                IEnumerable<string> files;
                try
                {
                    files = Directory.EnumerateDirectories(vsDir)
                        .Select(d => Path.Combine(d, "copilot-chat"))
                        .Where(Directory.Exists)
                        .SelectMany(Directory.EnumerateDirectories)
                        .Select(d => Path.Combine(d, "sessions"))
                        .Where(Directory.Exists)
                        .SelectMany(d => Directory.EnumerateFiles(d))
                        .ToList();
                }
                catch (Exception)
                {
                    continue;
                }

                foreach (var file in files)
                {
                    var info = new FileInfo(file);
                    if (latest == null || info.LastWriteTimeUtc > latest.LastWriteTimeUtc)
                        latest = info;
                }
            }
            return latest;
        }

        private static IEnumerable<string> CandidateVsDirs(string repoRoot, string? filePath)
        {
            var root = Path.GetFullPath(repoRoot).TrimEnd('\\', '/');
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            var dir = filePath != null ? Path.GetDirectoryName(Path.GetFullPath(filePath)) : null;
            while (dir != null && dir.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            {
                var vs = Path.Combine(dir, ".vs");
                if (seen.Add(vs) && Directory.Exists(vs))
                    yield return vs;
                if (string.Equals(dir.TrimEnd('\\', '/'), root, StringComparison.OrdinalIgnoreCase))
                    break;
                dir = Path.GetDirectoryName(dir);
            }

            var rootVs = Path.Combine(root, ".vs");
            if (seen.Add(rootVs) && Directory.Exists(rootVs))
                yield return rootVs;
        }

        /// <summary>
        /// Returns the last concrete model in the session, or null. Assistant messages give
        /// the model that actually answered; a user message's model is used only when it is
        /// not "auto" (auto is resolved by the following assistant message).
        /// </summary>
        internal static string? ExtractModel(byte[] bytes)
        {
            string? model = null;
            var reader = new MessagePackReader(bytes, bytes.Length > 0 && bytes[0] == 0x01 ? 1 : 0);
            while (!reader.End)
            {
                object? value;
                try
                {
                    value = reader.Read();
                }
                catch (Exception)
                {
                    break; // file may be mid-write; keep what we have
                }

                if (value is not List<object?> { Count: >= 2 } message
                    || message[1] is not Dictionary<string, object?> body
                    || !body.TryGetValue("Model", out var modelValue))
                {
                    continue;
                }

                var candidate = modelValue switch
                {
                    // assistant: [tag, { Id, Name, Family, ... }]
                    List<object?> { Count: >= 2 } union when union[1] is Dictionary<string, object?> info =>
                        AsModel(info, "Id") ?? AsModel(info, "Name") ?? AsModel(info, "Family"),
                    // user: { ModelId, Family, ... }
                    Dictionary<string, object?> request =>
                        AsModel(request, "ModelId") ?? AsModel(request, "Family"),
                    _ => null,
                };

                if (candidate != null)
                    model = candidate;
            }
            return model;
        }

        private static string? AsModel(Dictionary<string, object?> map, string key)
        {
            if (!map.TryGetValue(key, out var value) || value is not string s)
                return null;
            s = s.Trim();
            if (s.Length == 0
                || s.Equals("auto", StringComparison.OrdinalIgnoreCase)
                || s.Equals("copilot/auto", StringComparison.OrdinalIgnoreCase)
                || s.Equals(Unknown, StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }
            return s;
        }
    }

    /// <summary>
    /// Minimal MessagePack decoder. Maps become Dictionary&lt;string, object?&gt;, arrays
    /// List&lt;object?&gt;, strings string; bin/ext payloads are skipped (returned as null).
    /// </summary>
    internal sealed class MessagePackReader
    {
        private const int MaxDepth = 64;
        private readonly byte[] _buffer;
        private int _pos;

        public MessagePackReader(byte[] buffer, int offset = 0)
        {
            _buffer = buffer;
            _pos = offset;
        }

        public bool End => _pos >= _buffer.Length;

        public object? Read() => Read(0);

        private object? Read(int depth)
        {
            if (depth > MaxDepth)
                throw new InvalidDataException("MessagePack nesting too deep");

            var t = Next();
            if (t <= 0x7f) return (long)t;
            if (t >= 0xe0) return (long)(sbyte)t;
            if (t is >= 0x80 and <= 0x8f) return ReadMap(t & 0x0f, depth);
            if (t is >= 0x90 and <= 0x9f) return ReadArray(t & 0x0f, depth);
            if (t is >= 0xa0 and <= 0xbf) return ReadString(t & 0x1f);

            switch (t)
            {
                case 0xc0: return null;
                case 0xc2: return false;
                case 0xc3: return true;
                case 0xc4: Skip(ReadLength(1)); return null;
                case 0xc5: Skip(ReadLength(2)); return null;
                case 0xc6: Skip(ReadLength(4)); return null;
                case 0xc7: Skip(ReadLength(1) + 1); return null;
                case 0xc8: Skip(ReadLength(2) + 1); return null;
                case 0xc9: Skip(ReadLength(4) + 1); return null;
                case 0xca: return (double)BitConverter.ToSingle(BigEndian(4), 0);
                case 0xcb: return BitConverter.ToDouble(BigEndian(8), 0);
                case 0xcc: return (long)ReadUnsigned(1);
                case 0xcd: return (long)ReadUnsigned(2);
                case 0xce: return (long)ReadUnsigned(4);
                case 0xcf: return unchecked((long)ReadUnsigned(8));
                case 0xd0: return (long)(sbyte)ReadUnsigned(1);
                case 0xd1: return (long)(short)ReadUnsigned(2);
                case 0xd2: return (long)(int)ReadUnsigned(4);
                case 0xd3: return unchecked((long)ReadUnsigned(8));
                case 0xd4: Skip(2); return null;
                case 0xd5: Skip(3); return null;
                case 0xd6: Skip(5); return null;
                case 0xd7: Skip(9); return null;
                case 0xd8: Skip(17); return null;
                case 0xd9: return ReadString(ReadLength(1));
                case 0xda: return ReadString(ReadLength(2));
                case 0xdb: return ReadString(ReadLength(4));
                case 0xdc: return ReadArray(ReadLength(2), depth);
                case 0xdd: return ReadArray(ReadLength(4), depth);
                case 0xde: return ReadMap(ReadLength(2), depth);
                case 0xdf: return ReadMap(ReadLength(4), depth);
                default: throw new InvalidDataException($"Unsupported MessagePack type 0x{t:x2}");
            }
        }

        private byte Next()
        {
            if (_pos >= _buffer.Length) throw new EndOfStreamException();
            return _buffer[_pos++];
        }

        private void Skip(int count)
        {
            if (count < 0 || _pos + count > _buffer.Length) throw new EndOfStreamException();
            _pos += count;
        }

        private ulong ReadUnsigned(int size)
        {
            if (_pos + size > _buffer.Length) throw new EndOfStreamException();
            ulong value = 0;
            for (var i = 0; i < size; i++)
                value = (value << 8) | _buffer[_pos++];
            return value;
        }

        private int ReadLength(int size)
        {
            var value = ReadUnsigned(size);
            if (value > int.MaxValue) throw new InvalidDataException("MessagePack length too large");
            return (int)value;
        }

        private byte[] BigEndian(int size)
        {
            if (_pos + size > _buffer.Length) throw new EndOfStreamException();
            var bytes = new byte[size];
            Array.Copy(_buffer, _pos, bytes, 0, size);
            _pos += size;
            if (BitConverter.IsLittleEndian) Array.Reverse(bytes);
            return bytes;
        }

        private string ReadString(int length)
        {
            if (_pos + length > _buffer.Length) throw new EndOfStreamException();
            var s = Encoding.UTF8.GetString(_buffer, _pos, length);
            _pos += length;
            return s;
        }

        private List<object?> ReadArray(int count, int depth)
        {
            var list = new List<object?>(Math.Min(count, 1024));
            for (var i = 0; i < count; i++)
                list.Add(Read(depth + 1));
            return list;
        }

        private Dictionary<string, object?> ReadMap(int count, int depth)
        {
            var map = new Dictionary<string, object?>(Math.Min(count, 1024));
            for (var i = 0; i < count; i++)
            {
                var key = Read(depth + 1)?.ToString() ?? "";
                map[key] = Read(depth + 1);
            }
            return map;
        }
    }
}
