/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

For commercial licensing, please contact support@quantumnous.com
*/
import { THYSEED_LOGO } from '@/lib/constants'
import { cn } from '@/lib/utils'

type ThyseedBrandMarkProps = {
  className?: string
  imgClassName?: string
}

/**
 * 世喜 / thyseed 品牌标识
 * 源图为白字黑底；浅色主题 invert 为黑字并融入浅底，深色主题保持原样。
 */
export function ThyseedBrandMark({
  className,
  imgClassName,
}: ThyseedBrandMarkProps) {
  return (
    <img
      src={THYSEED_LOGO}
      alt='世喜'
      className={cn(
        'h-4 w-auto max-w-[6.25rem] shrink-0 object-contain object-left',
        'invert dark:invert-0',
        imgClassName,
        className
      )}
    />
  )
}
