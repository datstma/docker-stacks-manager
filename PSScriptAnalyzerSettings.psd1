# PSScriptAnalyzer settings for the PowerShell edition. CI fails on anything
# these rules report. Excluded rules don't fit a single-file interactive tool:
@{
    ExcludeRules = @(
        # The TUI draws with [Console]::Write on purpose (cursor control, no pipeline)
        'PSAvoidUsingWriteHost'
        # Script parameters are read by the functions through script scope
        'PSReviewUnusedParameter'
        # Docker calls take positional arguments like the docker CLI itself
        'PSAvoidUsingPositionalParameters'
        # Names such as Find-ComposeFiles and Get-WatchtowerLines read better plural
        'PSUseSingularNouns'
        # Restart/stop actions already ask for confirmation in the TUI
        'PSUseShouldProcessForStateChangingFunctions'
        # Empty catches are deliberate fallbacks (time zones, encodings, parsing)
        'PSAvoidUsingEmptyCatchBlock'
    )
}
