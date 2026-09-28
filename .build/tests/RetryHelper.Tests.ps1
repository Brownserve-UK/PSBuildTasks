#requires -Modules Pester, InvokeBuild

BeforeAll {
    $script:HarnessFile = Join-Path $Global:BrownserveRepoTestsDirectory 'Fixtures' 'RetryHelperHarness.tasks.ps1'

    function global:New-FakeHttpException
    {
        param
        (
            [int]$StatusCode,
            [hashtable]$Headers = @{}
        )
        $Response = [PSCustomObject]@{
            StatusCode = [System.Net.HttpStatusCode]$StatusCode
            Headers    = $Headers
        }
        $Exception = [System.Exception]::new("HTTP $StatusCode")
        $Exception | Add-Member -MemberType NoteProperty -Name 'Response' -Value $Response -Force
        return $Exception
    }

    function Invoke-RetryHarness
    {
        param
        (
            [scriptblock]$ScriptBlock,
            [scriptblock]$SleepScriptBlock,
            [int]$MaxAttempts = 3,
            [int]$BaseDelaySeconds = 2
        )
        $Global:RetryHarnessScriptBlock = $ScriptBlock
        $Global:RetryHarnessSleepScriptBlock = $SleepScriptBlock
        $Global:RetryHarnessMaxAttempts = $MaxAttempts
        $Global:RetryHarnessBaseDelaySeconds = $BaseDelaySeconds
        Invoke-Build RetryHarness -File $script:HarnessFile | Out-Null
        return [PSCustomObject]@{
            Result = $Global:RetryHarnessResult
            Error  = $Global:RetryHarnessError
        }
    }
}

AfterAll {
    Remove-Item -Path 'Function:\New-FakeHttpException' -ErrorAction 'SilentlyContinue'
    Remove-Variable -Scope 'Global' -ErrorAction 'SilentlyContinue' -Name @(
        'RetryHarnessScriptBlock',
        'RetryHarnessSleepScriptBlock',
        'RetryHarnessMaxAttempts',
        'RetryHarnessBaseDelaySeconds',
        'RetryHarnessResult',
        'RetryHarnessError',
        'RetryTestAttempts',
        'RetryTestSleepCalls',
        'RetryTestNoOpSleep'
    )
}

Describe 'Invoke-BrownserveRetry' {
    BeforeEach {
        $Global:RetryTestAttempts = 0
        $Global:RetryTestSleepCalls = [System.Collections.Generic.List[double]]::new()
        $Global:RetryTestNoOpSleep = { param($Seconds) $Global:RetryTestSleepCalls.Add($Seconds) }
    }

    It 'returns the result on first success without sleeping' {
        $Outcome = Invoke-RetryHarness -SleepScriptBlock $Global:RetryTestNoOpSleep -ScriptBlock { 'ok' }
        $Outcome.Error | Should -BeNullOrEmpty
        $Outcome.Result | Should -Be 'ok'
        $Global:RetryTestSleepCalls.Count | Should -Be 0
    }

    It 'retries a transient (HTTP 503) failure and succeeds on a later attempt' {
        $Outcome = Invoke-RetryHarness -SleepScriptBlock $Global:RetryTestNoOpSleep -ScriptBlock {
            $Global:RetryTestAttempts++
            if ($Global:RetryTestAttempts -lt 3)
            {
                throw (New-FakeHttpException -StatusCode 503)
            }
            'ok'
        }
        $Outcome.Error | Should -BeNullOrEmpty
        $Outcome.Result | Should -Be 'ok'
        $Global:RetryTestAttempts | Should -Be 3
        $Global:RetryTestSleepCalls.Count | Should -Be 2
    }

    It 'gives up after MaxAttempts on a persistent transient failure' {
        $Outcome = Invoke-RetryHarness -MaxAttempts 3 -SleepScriptBlock $Global:RetryTestNoOpSleep -ScriptBlock {
            $Global:RetryTestAttempts++
            throw (New-FakeHttpException -StatusCode 500)
        }
        $Outcome.Error | Should -Not -BeNullOrEmpty
        $Global:RetryTestAttempts | Should -Be 3
    }

    It 'backs off exponentially between attempts' {
        Invoke-RetryHarness -MaxAttempts 3 -BaseDelaySeconds 2 -SleepScriptBlock $Global:RetryTestNoOpSleep -ScriptBlock {
            $Global:RetryTestAttempts++
            throw (New-FakeHttpException -StatusCode 500)
        } | Out-Null
        @($Global:RetryTestSleepCalls) | Should -Be @(2, 4)
    }

    It 'honours a Retry-After header instead of the exponential backoff' {
        Invoke-RetryHarness -SleepScriptBlock $Global:RetryTestNoOpSleep -ScriptBlock {
            $Global:RetryTestAttempts++
            if ($Global:RetryTestAttempts -lt 2)
            {
                throw (New-FakeHttpException -StatusCode 429 -Headers @{ 'Retry-After' = '7' })
            }
            'ok'
        } | Out-Null
        @($Global:RetryTestSleepCalls) | Should -Be @(7)
    }

    It 'does not retry an authentication (401) error' {
        $Outcome = Invoke-RetryHarness -SleepScriptBlock $Global:RetryTestNoOpSleep -ScriptBlock {
            $Global:RetryTestAttempts++
            throw (New-FakeHttpException -StatusCode 401)
        }
        $Outcome.Error | Should -Not -BeNullOrEmpty
        $Global:RetryTestAttempts | Should -Be 1
        $Global:RetryTestSleepCalls.Count | Should -Be 0
    }

    It 'does not retry a validation (422) error' {
        $Outcome = Invoke-RetryHarness -SleepScriptBlock $Global:RetryTestNoOpSleep -ScriptBlock {
            $Global:RetryTestAttempts++
            throw (New-FakeHttpException -StatusCode 422)
        }
        $Outcome.Error | Should -Not -BeNullOrEmpty
        $Global:RetryTestAttempts | Should -Be 1
    }

    It 'does not retry a plain, non-HTTP error' {
        $Outcome = Invoke-RetryHarness -SleepScriptBlock $Global:RetryTestNoOpSleep -ScriptBlock {
            $Global:RetryTestAttempts++
            throw 'Something unrelated went wrong'
        }
        $Outcome.Error | Should -Not -BeNullOrEmpty
        $Global:RetryTestAttempts | Should -Be 1
    }
}
