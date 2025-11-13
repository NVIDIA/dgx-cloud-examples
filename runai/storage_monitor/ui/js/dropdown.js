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
    function closeOptions(optionsEl) {
        if (optionsEl) {
            optionsEl.classList.remove('open');
        }
    }

    function openOptions(optionsEl) {
        if (optionsEl) {
            optionsEl.classList.add('open');
        }
    }

    function bindOptionHover(option) {
        if (option.dataset.dropdownHoverBound === 'true') {
            return;
        }
        option.addEventListener('mouseenter', () => option.classList.add('hover'));
        option.addEventListener('mouseleave', () => option.classList.remove('hover'));
        option.dataset.dropdownHoverBound = 'true';
    }

    function handleOptionSelection(dropdownEl, option, onSelect) {
        const value = option.dataset.value;
        const text = option.textContent;

        dropdownEl.querySelectorAll('.custom-dropdown-option').forEach(o => o.classList.remove('selected'));
        option.classList.add('selected');

        const labelEl = dropdownEl.querySelector('.custom-dropdown-selected span');
        if (labelEl) {
            labelEl.textContent = text;
        }

        if (typeof onSelect === 'function') {
            onSelect(value, option);
        }

        dropdownEl.classList.remove('open');
        closeOptions(dropdownEl.querySelector('.custom-dropdown-options'));
    }

    function initCustomDropdown(dropdownEl, onSelect) {
        if (!dropdownEl) return;

        dropdownEl.classList.add('custom-dropdown');
        const selected = dropdownEl.querySelector('.custom-dropdown-selected');
        const options = dropdownEl.querySelector('.custom-dropdown-options');

        if (!selected || !options) {
            return;
        }

        if (selected.dataset.dropdownToggleBound !== 'true') {
            selected.addEventListener('click', (event) => {
                event.stopPropagation();
                closeAllDropdowns();
                const isOpen = dropdownEl.classList.toggle('open');
                if (isOpen) {
                    openOptions(options);
                } else {
                    closeOptions(options);
                }
            });
            selected.dataset.dropdownToggleBound = 'true';
        }

        options.querySelectorAll('.custom-dropdown-option').forEach(option => {
            bindOptionHover(option);
            if (option.dataset.dropdownClickBound === 'true') {
                return;
            }
            option.addEventListener('click', (event) => {
                event.stopPropagation();
                handleOptionSelection(dropdownEl, option, onSelect);
            });
            option.dataset.dropdownClickBound = 'true';
        });
    }

    function closeAllDropdowns() {
        document.querySelectorAll('.custom-dropdown').forEach(dropdown => dropdown.classList.remove('open'));
        document.querySelectorAll('.custom-dropdown-options').forEach(closeOptions);
    }

    document.addEventListener('click', (event) => {
        if (!event.target.closest('.custom-dropdown')) {
            closeAllDropdowns();
        }
    });

    global.NvidiaDropdown = {
        initCustomDropdown,
        closeAllDropdowns
    };
})(window);

