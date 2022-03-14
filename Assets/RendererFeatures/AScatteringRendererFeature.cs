using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

namespace RendererFeatures
{
    public class AScatteringRendererFeature : ScriptableRendererFeature
    {

        [System.Serializable]
        public class AScatteringSettings
        {
            // we're free to put whatever we want here, public fields will be exposed in the inspector
            public bool IsEnabled = true;
            public RenderPassEvent WhenToInsert = RenderPassEvent.AfterRendering;
            public Material MaterialToBlit;
            public float scatteringStrength = 20;
            public Vector3 waveLengths = new Vector3 (700, 530, 460);
        }

        // MUST be named "settings" (lowercase) to be shown in the Render Features inspector
        public AScatteringSettings settings = new AScatteringSettings();

        RTHandle renderTextureHandle;
        // RenderTargetHandle renderTextureHandle;
        AScatteringRenderPass renderPass;

        /// <inheritdoc/>
        public override void Create()
        {
            renderPass = new AScatteringRenderPass(
                "Atmospheric Scattering",
                settings.WhenToInsert,
                settings.MaterialToBlit,
                settings.scatteringStrength,
                settings.waveLengths);
            // Configures where the render pass should be injected.
        }

        public override void SetupRenderPasses(ScriptableRenderer renderer, in RenderingData renderingData)
        {
            base.SetupRenderPasses(renderer, in renderingData);
            // Gather up and pass any extra information our pass will need.
            // In this case we're getting the camera's color buffer target
            var cameraColorTargetIdent = renderer.cameraColorTargetHandle;
            renderPass.Setup(cameraColorTargetIdent);
        }

        // Here you can inject one or multiple render passes in the renderer.
        // This method is called when setting up the renderer once per-camera.
        public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
        {
            if (!settings.IsEnabled)
            {
                // we can do nothing this frame if we want
                return;
            }
    
           
            
            renderer.EnqueuePass(renderPass);
        }
    }
}


