/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
*/
import { useEffect, useRef } from 'react'
import i18next from 'i18next'
import { toast } from 'sonner'
import { api } from '@/lib/api'
import { useStatus } from '@/hooks/use-status'
import { useAuthRedirect } from '@/features/auth/hooks/use-auth-redirect'
import { useAuthStore, type AuthUser } from '@/stores/auth-store'

const SSO_CODE_PARAM = 'sso_code'
const DEFAULT_SSO_API_ORIGIN = 'https://portalapi.thyseed.com'

function consumeSsoCodeFromUrl(): string | null {
  const params = new URLSearchParams(window.location.search)
  const code = params.get(SSO_CODE_PARAM)
  if (!code) return null
  params.delete(SSO_CODE_PARAM)
  const nextSearch = params.toString()
  window.history.replaceState(
    null,
    '',
    window.location.pathname +
      (nextSearch ? `?${nextSearch}` : '') +
      window.location.hash
  )
  return code
}

function resolveSsoApiOrigin(status: Record<string, unknown> | null | undefined) {
  const fromStatus =
    status?.thyseed_sso_api_origin ??
    (status?.data as Record<string, unknown> | undefined)?.thyseed_sso_api_origin
  const fromEnv = import.meta.env.VITE_SSO_API_ORIGIN
  const raw = (fromStatus || fromEnv || DEFAULT_SSO_API_ORIGIN).toString().trim()
  return raw.replace(/\/$/, '')
}

function resolvePortalUrl(status: Record<string, unknown> | null | undefined) {
  const fromStatus =
    status?.thyseed_sso_portal_url ??
    (status?.data as Record<string, unknown> | undefined)?.thyseed_sso_portal_url
  const fromEnv = import.meta.env.VITE_PORTAL_URL
  const raw = (fromStatus || fromEnv || '').toString().trim()
  return raw.replace(/\/$/, '')
}

async function exchangeSsoCode(
  code: string,
  ssoApiOrigin: string
): Promise<string> {
  const resp = await fetch(`${ssoApiOrigin}/api/sso/auth/exchange`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body: JSON.stringify({ code }),
  })
  if (!resp.ok) {
    throw new Error(`exchange failed: ${resp.status}`)
  }
  const payload = (await resp.json()) as Record<string, unknown>
  const data = (payload.data as Record<string, unknown> | undefined) || payload
  const access = (data.token || data.access_token) as string | undefined
  if (!access) {
    throw new Error('exchange response missing token')
  }
  return access
}

export function buildThyseedPortalLoginUrl(
  portalUrl: string,
  redirectUri?: string
): string {
  const base = portalUrl.replace(/\/$/, '')
  const target =
    redirectUri || `${window.location.origin}/sign-in`
  return `${base}/login?redirect_uri=${encodeURIComponent(target)}`
}

export function useThyseedSsoCallback(options?: { redirectTo?: string }) {
  const { status } = useStatus()
  const { handleLoginSuccess } = useAuthRedirect()
  const runningRef = useRef(false)

  useEffect(() => {
    if (runningRef.current) return
    const params = new URLSearchParams(window.location.search)
    const pendingCode = params.get(SSO_CODE_PARAM)
    if (!pendingCode) return

    runningRef.current = true
    const code = consumeSsoCodeFromUrl()
    if (!code) {
      runningRef.current = false
      return
    }
    ;(async () => {
      try {
        const ssoOrigin = resolveSsoApiOrigin(
          status as Record<string, unknown> | null
        )
        if (!ssoOrigin) {
          toast.error(i18next.t('SSO is not configured'))
          return
        }
        const accessToken = await exchangeSsoCode(code, ssoOrigin)
        const res = await api.post('/api/user/sso/login', null, {
          headers: { Authorization: `Bearer ${accessToken}` },
          skipBusinessError: true,
        } as Record<string, unknown>)
        const body = res?.data as {
          success?: boolean
          message?: string
          data?: AuthUser
        }
        if (!body?.success) {
          toast.error(body?.message || i18next.t('SSO login failed'))
          return
        }
        if (body.data) {
          useAuthStore.getState().auth.setUser(body.data)
        }
        await handleLoginSuccess(body.data, options?.redirectTo)
      } catch {
        toast.error(i18next.t('SSO login failed'))
      } finally {
        runningRef.current = false
      }
    })()
  }, [status, handleLoginSuccess, options?.redirectTo])
}

export function useThyseedPortalLoginUrl() {
  const { status } = useStatus()
  const enabled = Boolean(
    status?.thyseed_sso_enabled ??
      (status?.data as Record<string, unknown> | undefined)?.thyseed_sso_enabled
  )
  const portalUrl = resolvePortalUrl(status as Record<string, unknown> | null)
  if (!enabled || !portalUrl) return null
  return buildThyseedPortalLoginUrl(portalUrl)
}
