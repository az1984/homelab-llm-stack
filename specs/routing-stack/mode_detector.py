# mode_detector.py
from typing import Set, Optional
from config import config

class ModeDetector:
    """Detects the appropriate mode based on request content."""
    
    def detect_mode(self, messages: list) -> str:
        """
        Detect mode from conversation messages.
        Returns mode name or default mode if no match.
        """
        if not config.ENABLE_MODE_DETECTION:
            return config.DEFAULT_MODE
        
        # Extract text from messages
        text = self._extract_text(messages)
        if not text:
            return config.DEFAULT_MODE
        
        text_lower = text.lower()
        
        # Check modes in priority order
        for mode_name in config.get_enabled_modes():
            mode_config = config.MODES[mode_name]
            
            # Skip default mode (checked last)
            if mode_name == config.DEFAULT_MODE:
                continue
            
            # Check if keywords match
            if self._matches_mode(text_lower, mode_config.keywords):
                return mode_name
        
        return config.DEFAULT_MODE
    
    def _matches_mode(self, text: str, keywords: Set[str]) -> bool:
        """Check if text matches mode keywords."""
        if not keywords:
            return False
        
        matches = sum(1 for keyword in keywords if keyword in text)
        
        if config.MODE_DETECTION_STRICT:
            # Strict: all keywords must match
            return matches == len(keywords)
        else:
            # Fuzzy: check if match ratio exceeds threshold
            match_ratio = matches / len(keywords) if keywords else 0
            return match_ratio >= config.MODE_DETECTION_THRESHOLD
    
    def _extract_text(self, messages: list) -> str:
        """Extract text content from messages."""
        text_parts = []
        
        for msg in messages:
            if isinstance(msg.get('content'), str):
                text_parts.append(msg['content'])
            elif isinstance(msg.get('content'), list):
                for item in msg['content']:
                    if isinstance(item, dict) and item.get('type') == 'text':
                        text_parts.append(item.get('text', ''))
        
        return ' '.join(text_parts)
