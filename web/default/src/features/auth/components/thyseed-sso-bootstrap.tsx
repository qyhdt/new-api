/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.
*/
import { useSearch } from '@tanstack/react-router'
import { useThyseedSsoCallback } from '@/features/auth/hooks/use-thyseed-sso'

export function ThyseedSsoBootstrap() {
  const search = useSearch({ strict: false }) as { redirect?: string }
  useThyseedSsoCallback({ redirectTo: search?.redirect })
  return null
}
