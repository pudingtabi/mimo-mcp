#!/usr/bin/env python3
"""
PDF Text Extractor Script
Extracts text content from a PDF file using PyPDF2 library.
"""

import sys
import os
from typing import Optional

try:
    import PyPDF2
except ImportError:
    print("PyPDF2 library not found. Installing...")
    os.system("pip3 install PyPDF2")
    try:
        import PyPDF2
    except ImportError:
        print("Failed to install PyPDF2. Please install manually: pip3 install PyPDF2")
        sys.exit(1)

def extract_text_from_pdf(pdf_path: str) -> Optional[str]:
    """
    Extract text content from a PDF file.
    
    Args:
        pdf_path: Path to the PDF file
        
    Returns:
        Extracted text content or None if error occurs
    """
    try:
        # Check if file exists
        if not os.path.exists(pdf_path):
            print(f"Error: PDF file not found at {pdf_path}")
            return None
            
        # Check if file is readable
        if not os.access(pdf_path, os.R_OK):
            print(f"Error: Cannot read PDF file at {pdf_path}")
            return None
            
        # Open the PDF file
        with open(pdf_path, 'rb') as file:
            # Create PDF reader object
            pdf_reader = PyPDF2.PdfReader(file)
            
            # Get number of pages
            num_pages = len(pdf_reader.pages)
            print(f"PDF contains {num_pages} page(s)")
            
            # Extract text from all pages
            full_text = ""
            
            for page_num in range(num_pages):
                try:
                    page = pdf_reader.pages[page_num]
                    text = page.extract_text()
                    
                    if text:
                        full_text += f"\n--- Page {page_num + 1} ---\n"
                        full_text += text
                        full_text += "\n"
                    else:
                        print(f"Warning: No text found on page {page_num + 1}")
                        
                except Exception as e:
                    print(f"Error extracting text from page {page_num + 1}: {e}")
                    continue
            
            return full_text.strip()
            
    except PyPDF2.errors.PdfReadError as e:
        print(f"Error reading PDF file: {e}")
        return None
    except Exception as e:
        print(f"Unexpected error: {e}")
        return None

def main():
    """Main function to handle command line execution."""
    # PDF file path
    pdf_path = "/workspace/mrc-server/mimo-mcp/document.pdf"
    
    print(f"Extracting text from PDF: {pdf_path}")
    print("-" * 50)
    
    # Extract text
    extracted_text = extract_text_from_pdf(pdf_path)
    
    if extracted_text:
        print("\nExtracted text content:")
        print("=" * 50)
        print(extracted_text)
        print("=" * 50)
        
        # Save to file for easier reading
        output_path = "/workspace/mrc-server/mimo-mcp/document_extracted.txt"
        try:
            with open(output_path, 'w', encoding='utf-8') as f:
                f.write(extracted_text)
            print(f"\nText also saved to: {output_path}")
        except Exception as e:
            print(f"Warning: Could not save extracted text to file: {e}")
            
    else:
        print("Failed to extract text from PDF")
        sys.exit(1)

if __name__ == "__main__":
    main()