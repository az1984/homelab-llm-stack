# config.py
"""
Central configuration for the proxy server.
Allows tuning of routing logic, mode detection, and endpoints without code changes.
"""

from dataclasses import dataclass
from typing import Dict, List, Set
import os


@dataclass
class ModeConfig:
    """Configuration for a specific mode."""
    name: str
    keywords: Set[str]
    priority: int  # Higher priority modes checked first
    enabled: bool = True


@dataclass
class EndpointConfig:
    """Configuration for an API endpoint."""
    hostname: str
    path: str
    api_key_env_var: str  # Environment variable name for API key
    timeout: int = 30
    max_retries: int = 3


class ProxyConfig:
    """Main configuration class for the proxy server."""
    
    # ============================================================================
    # MODE DETECTION CONFIGURATION
    # ============================================================================
    
    MODES = {
        'extended_thinking': ModeConfig(
            name='extended_thinking',
            keywords={
                'think', 'reasoning', 'analyze', 'complex', 'deep',
                'reasoning step', 'chain of thought', 'work through',
                'think through', 'break down', 'analyze carefully'
            },
            priority=100,
            enabled=True
        ),
        'analysis': ModeConfig(
            name='analysis',
            keywords={
                'analyze', 'compare', 'evaluate', 'assess', 'examine',
                'review', 'critique', 'study', 'investigate'
            },
            priority=90,
            enabled=True
        ),
        'creative': ModeConfig(
            name='creative',
            keywords={
                'write', 'create', 'story', 'poem', 'creative',
                'imagine', 'draft', 'compose', 'generate'
            },
            priority=80,
            enabled=True
        ),
        'coding': ModeConfig(
            name='coding',
            keywords={
                'code', 'function', 'class', 'debug', 'implement',
                'refactor', 'algorithm', 'program', 'script'
            },
            priority=85,
            enabled=True
        ),
        'default': ModeConfig(
            name='default',
            keywords=set(),  # Always matches
            priority=0,
            enabled=True
        )
    }
    
    # Default mode when no keywords match
    DEFAULT_MODE = 'default'
    
    # Minimum keyword match score to trigger mode (0.0 to 1.0)
    MODE_DETECTION_THRESHOLD = 0.3
    
    # Whether to use strict matching (all keywords) or fuzzy (any keyword)
    MODE_DETECTION_STRICT = False
    
    # ============================================================================
    # ENDPOINT CONFIGURATION
    # ============================================================================
    
    ENDPOINTS = {
        'extended_thinking': EndpointConfig(
            hostname='api.anthropic.com',
            path='/v1/messages',
            api_key_env_var='ANTHROPIC_API_KEY_EXTENDED',
            timeout=60,  # Extended thinking may take longer
            max_retries=2
        ),
        'analysis': EndpointConfig(
            hostname='api.anthropic.com',
            path='/v1/messages',
            api_key_env_var='ANTHROPIC_API_KEY_ANALYSIS',
            timeout=45,
            max_retries=3
        ),
        'creative': EndpointConfig(
            hostname='api.anthropic.com',
            path='/v1/messages',
            api_key_env_var='ANTHROPIC_API_KEY_CREATIVE',
            timeout=30,
            max_retries=3
        ),
        'coding': EndpointConfig(
            hostname='api.anthropic.com',
            path='/v1/messages',
            api_key_env_var='ANTHROPIC_API_KEY_CODING',
            timeout=45,
            max_retries=3
        ),
        'default': EndpointConfig(
            hostname='api.anthropic.com',
            path='/v1/messages',
            api_key_env_var='ANTHROPIC_API_KEY',
            timeout=30,
            max_retries=3
        )
    }
    
    # ============================================================================
    # MODEL CONFIGURATION
    # ============================================================================
    
    # Default models for each mode (can be overridden by request)
    DEFAULT_MODELS = {
        'extended_thinking': 'claude-opus-4-20250514',
        'analysis': 'claude-sonnet-4-20250514',
        'creative': 'claude-sonnet-4-20250514',
        'coding': 'claude-sonnet-4-20250514',
        'default': 'claude-sonnet-4-20250514'
    }
    
    # ============================================================================
    # PARAMETER OVERRIDES
    # ============================================================================
    
    # Default parameter overrides for each mode
    PARAMETER_OVERRIDES = {
        'extended_thinking': {
            'thinking': {
                'type': 'enabled',
                'budget_tokens': 10000
            }
        },
        'analysis': {
            'temperature': 0.7
        },
        'creative': {
            'temperature': 1.0
        },
        'coding': {
            'temperature': 0.5
        },
        'default': {}
    }
    
    # ============================================================================
    # PROXY SERVER CONFIGURATION
    # ============================================================================
    
    # Server host and port
    HOST = os.getenv('PROXY_HOST', '0.0.0.0')
    PORT = int(os.getenv('PROXY_PORT', '8000'))
    
    # Request/Response settings
    MAX_REQUEST_SIZE = 10 * 1024 * 1024  # 10MB
    BUFFER_SIZE = 8192
    
    # Logging configuration
    LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')
    LOG_FILE = os.getenv('LOG_FILE', 'proxy.log')
    LOG_REQUESTS = os.getenv('LOG_REQUESTS', 'true').lower() == 'true'
    
    # ============================================================================
    # FEATURE FLAGS
    # ============================================================================
    
    # Enable/disable specific features
    ENABLE_MODE_DETECTION = True
    ENABLE_PARAMETER_OVERRIDE = True
    ENABLE_MODEL_OVERRIDE = True
    ENABLE_CACHING = False  # For future caching implementation
    ENABLE_RATE_LIMITING = False  # For future rate limiting
    
    # ============================================================================
    # HELPER METHODS
    # ============================================================================
    
    @classmethod
    def get_endpoint(cls, mode: str) -> EndpointConfig:
        """Get endpoint configuration for a mode."""
        return cls.ENDPOINTS.get(mode, cls.ENDPOINTS[cls.DEFAULT_MODE])
    
    @classmethod
    def get_api_key(cls, mode: str) -> str:
        """Get API key for a mode from environment."""
        endpoint = cls.get_endpoint(mode)
        api_key = os.getenv(endpoint.api_key_env_var)
        
        # Fallback to default API key if mode-specific key not found
        if not api_key and mode != cls.DEFAULT_MODE:
            default_key_var = cls.ENDPOINTS[cls.DEFAULT_MODE].api_key_env_var
            api_key = os.getenv(default_key_var)
        
        return api_key
    
    @classmethod
    def get_enabled_modes(cls) -> List[str]:
        """Get list of enabled modes sorted by priority."""
        enabled = [(name, config) for name, config in cls.MODES.items() 
                   if config.enabled]
        return [name for name, _ in sorted(enabled, 
                                          key=lambda x: x[1].priority, 
                                          reverse=True)]
    
    @classmethod
    def get_mode_keywords(cls, mode: str) -> Set[str]:
        """Get keywords for a specific mode."""
        return cls.MODES.get(mode, cls.MODES[cls.DEFAULT_MODE]).keywords
    
    @classmethod
    def get_default_model(cls, mode: str) -> str:
        """Get default model for a mode."""
        return cls.DEFAULT_MODELS.get(mode, cls.DEFAULT_MODELS[cls.DEFAULT_MODE])
    
    @classmethod
    def get_parameter_overrides(cls, mode: str) -> Dict:
        """Get parameter overrides for a mode."""
        return cls.PARAMETER_OVERRIDES.get(mode, {}).copy()
    
    @classmethod
    def validate_config(cls) -> List[str]:
        """Validate configuration and return list of warnings/errors."""
        issues = []
        
        # Check that all modes have corresponding endpoints
        for mode in cls.MODES:
            if mode not in cls.ENDPOINTS:
                issues.append(f"Mode '{mode}' has no endpoint configuration")
        
        # Check that API keys are available
        for mode, endpoint in cls.ENDPOINTS.items():
            if not os.getenv(endpoint.api_key_env_var):
                issues.append(
                    f"API key not found for {mode} "
                    f"(expected env var: {endpoint.api_key_env_var})"
                )
        
        # Check that default mode exists
        if cls.DEFAULT_MODE not in cls.MODES:
            issues.append(f"Default mode '{cls.DEFAULT_MODE}' not found in MODES")
        
        return issues


# For convenience, create a singleton instance
config = ProxyConfig()
