using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using GitAiVS.Services;
using Microsoft.VisualStudio.TestTools.UnitTesting;

namespace GitAiVS.Tests
{
    [TestClass]
    public class CopilotModelResolverTests
    {
        // --- tiny MessagePack writer for fixtures ---------------------------------
        private static void Str(List<byte> o, string s)
        {
            var b = Encoding.UTF8.GetBytes(s);
            if (b.Length < 32) o.Add((byte)(0xa0 | b.Length));
            else { o.Add(0xd9); o.Add((byte)b.Length); }
            o.AddRange(b);
        }

        private static void MapHeader(List<byte> o, int n) => o.Add((byte)(0x80 | n));
        private static void ArrHeader(List<byte> o, int n) => o.Add((byte)(0x90 | n));

        private static void Header(List<byte> o)
        {
            MapHeader(o, 2);
            Str(o, "Name"); o.Add(0xc0);
            Str(o, "TimeCreated"); o.Add(0xd7); o.Add(0xff); o.AddRange(new byte[8]); // ext timestamp
        }

        private static void UserMessage(List<byte> o, string modelId)
        {
            ArrHeader(o, 2); o.Add(0x00);
            MapHeader(o, 2);
            Str(o, "Content"); o.Add(0xc4); o.Add(2); o.Add(1); o.Add(2); // bin payload
            Str(o, "Model"); MapHeader(o, 2);
            Str(o, "Family"); Str(o, modelId);
            Str(o, "ModelId"); Str(o, modelId);
        }

        private static void AssistantMessage(List<byte> o, string? id)
        {
            ArrHeader(o, 2); o.Add(0x01);
            MapHeader(o, 1);
            Str(o, "Model");
            if (id == null) { o.Add(0xc0); return; }
            ArrHeader(o, 2); o.Add(0x00);
            MapHeader(o, 2);
            Str(o, "Id"); Str(o, id);
            Str(o, "DisplayName"); Str(o, id.ToUpperInvariant());
        }

        private static byte[] Session(Action<List<byte>> body)
        {
            var o = new List<byte> { 0x01 };
            Header(o);
            body(o);
            return o.ToArray();
        }

        [TestMethod]
        public void UsesAssistantModel()
        {
            var bytes = Session(o =>
            {
                UserMessage(o, "gpt-5.6-luna");
                AssistantMessage(o, "gpt-5.6-luna");
            });
            Assert.AreEqual("gpt-5.6-luna", CopilotModelResolver.ExtractModel(bytes));
        }

        [TestMethod]
        public void AutoRequestResolvedByAssistant()
        {
            var bytes = Session(o =>
            {
                UserMessage(o, "auto");
                AssistantMessage(o, "claude-sonnet-4.5");
            });
            Assert.AreEqual("claude-sonnet-4.5", CopilotModelResolver.ExtractModel(bytes));
        }

        [TestMethod]
        public void LaterTurnWinsAndAutoWithoutAnswerKeepsPrevious()
        {
            var bytes = Session(o =>
            {
                UserMessage(o, "gpt-4.1");
                AssistantMessage(o, "gpt-4.1");
                UserMessage(o, "gpt-5.6-luna");
                AssistantMessage(o, "gpt-5.6-luna");
                UserMessage(o, "auto");
                AssistantMessage(o, null);
            });
            Assert.AreEqual("gpt-5.6-luna", CopilotModelResolver.ExtractModel(bytes));
        }

        [TestMethod]
        public void TruncatedFileKeepsCompleteMessages()
        {
            var bytes = Session(o =>
            {
                UserMessage(o, "gpt-4.1");
                AssistantMessage(o, "gpt-4.1");
                UserMessage(o, "gpt-5-mini");
            });
            Array.Resize(ref bytes, bytes.Length - 3);
            Assert.AreEqual("gpt-4.1", CopilotModelResolver.ExtractModel(bytes));
        }

        [TestMethod]
        public void NoModelReturnsNull()
        {
            var bytes = Session(o => UserMessage(o, "auto"));
            Assert.IsNull(CopilotModelResolver.ExtractModel(bytes));
        }

        [TestMethod]
        public void ResolveFindsNewestSessionUnderSolutionVsFolder()
        {
            var root = Path.Combine(Path.GetTempPath(), "gitai-vs-" + Guid.NewGuid().ToString("N"));
            try
            {
                var solutionDir = Path.Combine(root, "src", "App");
                var sessions = Path.Combine(solutionDir, ".vs", "App.slnx", "copilot-chat", "abcd1234", "sessions");
                Directory.CreateDirectory(sessions);

                var old = Path.Combine(sessions, "old");
                File.WriteAllBytes(old, Session(o => AssistantMessage(o, "gpt-4.1")));
                File.SetLastWriteTimeUtc(old, DateTime.UtcNow.AddHours(-1));
                File.WriteAllBytes(Path.Combine(sessions, "new"), Session(o => AssistantMessage(o, "gpt-5.6-luna")));

                var edited = Path.Combine(solutionDir, "Program.cs");
                Assert.AreEqual("gpt-5.6-luna", CopilotModelResolver.Resolve(root, edited));
            }
            finally
            {
                try { Directory.Delete(root, true); } catch { }
            }
        }

        [TestMethod]
        public void ResolveWithoutSessionsReturnsUnknown()
        {
            var root = Path.Combine(Path.GetTempPath(), "gitai-vs-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(root);
            try
            {
                Assert.AreEqual("unknown", CopilotModelResolver.Resolve(root, Path.Combine(root, "a.cs")));
            }
            finally
            {
                Directory.Delete(root, true);
            }
        }
    }
}
