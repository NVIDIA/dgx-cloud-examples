(function (global) {
    async function fetchJson(url, options = {}) {
        const response = await fetch(url, options);
        if (!response.ok) {
            const error = new Error(`Request failed with status ${response.status}`);
            error.status = response.status;
            try {
                error.body = await response.text();
            } catch (bodyReadError) {
                error.body = null;
            }
            throw error;
        }
        return response.json();
    }

    global.NvidiaApiClient = {
        fetchJson
    };
})(window);

