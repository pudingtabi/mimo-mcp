defmodule Mimo.Brain.LLMSanitizationTest do
  use ExUnit.Case, async: true

  alias Mimo.Brain.LLM

  describe "sanitize_text_for_embedding/1" do
    test "handles normal text unchanged" do
      text = "Hello, this is a normal text."
      result = LLM.sanitize_text_for_embedding(text)
      assert result == text
    end

    test "strips excessive combining characters (zalgo text)" do
      # Create zalgo-like text with many combining chars
      # Base 'e' followed by many combining chars (60 total)
      zalgo = "e" <> String.duplicate("\u0303\u0304\u0305\u0306\u0307\u0308", 10)
      result = LLM.sanitize_text_for_embedding(zalgo)
      
      # Original has 60 codepoints, result should have only 4 (base + 3 combiners)
      result_codepoints = String.to_charlist(result)
      assert length(result_codepoints) == 4
      
      # Byte size should be much smaller
      assert byte_size(result) < byte_size(zalgo)
    end

    test "truncates very long text" do
      # Create text longer than max (8000 chars)
      long_text = String.duplicate("a", 10_000)
      result = LLM.sanitize_text_for_embedding(long_text)
      
      # Should be truncated to max length
      assert String.length(result) == 8_000
    end

    test "handles mixed zalgo and normal text" do
      # Mix of normal chars and zalgo (20 combining chars after 'z')
      text = "normal " <> "z" <> String.duplicate("\u0303", 20) <> " more normal"
      result = LLM.sanitize_text_for_embedding(text)
      
      # Should contain the normal parts
      assert String.contains?(result, "normal")
      assert String.contains?(result, "more normal")
      
      # The zalgo character should be reduced - check byte size is smaller
      assert byte_size(result) < byte_size(text)
    end

    test "handles empty string" do
      assert LLM.sanitize_text_for_embedding("") == ""
    end

    test "handles nil" do
      assert LLM.sanitize_text_for_embedding(nil) == ""
    end

    test "trims whitespace" do
      text = "  hello world  "
      result = LLM.sanitize_text_for_embedding(text)
      assert result == "hello world"
    end

    test "handles emoji with ZWJ sequences" do
      # Family emoji with zero-width joiners
      text = "Hello 👨‍👩‍👧‍👦 World"
      result = LLM.sanitize_text_for_embedding(text)
      
      # Should contain the text parts
      assert String.contains?(result, "Hello")
      assert String.contains?(result, "World")
    end

    test "handles RTL text" do
      # Arabic text
      text = "مرحبا Hello"
      result = LLM.sanitize_text_for_embedding(text)
      
      # Should contain both
      assert String.contains?(result, "Hello")
      assert String.contains?(result, "م")
    end

    test "normalizes to NFC form" do
      # NFD form: e + combining acute accent
      nfd = "e\u0301"
      result = LLM.sanitize_text_for_embedding(nfd)
      
      # Should be normalized to NFC (single char é)
      assert result == "é"
    end

    test "preserves reasonable combining chars" do
      # Normal accented text with 1-2 combining chars is fine
      text = "café rsumé naïve"
      result = LLM.sanitize_text_for_embedding(text)
      # Should be unchanged
      assert result == text
    end
  end
end
