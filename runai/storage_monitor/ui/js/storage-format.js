/*
 * SPDX-FileCopyrightText: Copyright (c) 2024-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

(function (global) {
    const DEFAULT_FRACTION_DIGITS = 2;

    const unitConfig = {
        gi: { label: 'GiB (1024-based)', divisor: 1, suffix: 'GiB' },
        gb: { label: 'GB (1000-based)', divisor: 1.073741824, suffix: 'GB' },
        ti: { label: 'TiB (1024-based)', divisor: 1024, suffix: 'TiB' },
        tb: { label: 'TB (1000-based)', divisor: 1099.511627776, suffix: 'TB' }
    };

    function normalizeValue(value) {
        const numericValue = Number(value);
        return Number.isFinite(numericValue) ? numericValue : 0;
    }

    function formatStorageValue(value, fractionDigits = DEFAULT_FRACTION_DIGITS) {
        const normalized = normalizeValue(value);
        return normalized.toLocaleString('en-US', {
            minimumFractionDigits: fractionDigits,
            maximumFractionDigits: fractionDigits
        });
    }

    function convertStorage(gi, unitKey) {
        const config = unitConfig[unitKey] || unitConfig.gi;
        const normalizedGi = normalizeValue(gi);
        const convertedValue = normalizedGi / config.divisor;
        return `${formatStorageValue(convertedValue)} ${config.suffix}`;
    }

    // Expose helpers for pages that expect specific function names
    global.NvidiaStorageFormat = {
        unitConfig,
        formatStorageValue,
        convertStorage,
        convertCapacity: convertStorage
    };
})(window);

